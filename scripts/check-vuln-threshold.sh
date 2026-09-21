#!/usr/bin/env bash
# Apply the release threshold to a Grype JSON report.
#
# Usage: check-vuln-threshold.sh GRYPE_JSON [LABEL]
#        check-vuln-threshold.sh --validate-exceptions FILE
#
# Environment (configurable; set as repository variables in CI):
#   VULN_FAIL_ON          none | critical | high     (default: critical)
#       critical  block on Critical, report High without blocking   <- default
#       high      block on Critical and High
#       none      never block; report only
#   VULN_IGNORE_UNFIXED   true | false               (default: false; CI default: true)
#       true: findings without an available fix (distro "won't fix" / "not
#       fixed") never block; they are still reported. Blocks only what a
#       rebuild could actually fix.
#   VULN_EXCEPTIONS_FILE  path of a reviewed exception list (default: none)
#   VULN_VARIANT          variant being scanned (debian|alpine); exceptions apply per variant
#   VULN_TODAY            override "today" (YYYY-MM-DD) for tests
#
# Exceptions (.github/vuln-exceptions.json) are for findings that ARE fixable
# upstream but not yet in a package we can install (e.g. a library vendored in
# a distro binary). Each entry is scoped to vulnerability ids + package + file
# locations + variants, needs a reason, and EXPIRES: after `expires` it no
# longer applies and the findings block again. Applied exceptions are always
# listed in the log and summary. See docs/ci-cd.md.
#
# Exit: 0 pass, 1 blocked by threshold, 2 usage/input error.
set -euo pipefail

today="${VULN_TODAY:-$(date -u +%F)}"

# --- exception file validation -------------------------------------------------
validate_exceptions() { # validate_exceptions <file>
  local file="$1"
  [ -f "$file" ] || { echo "exceptions file not found: $file" >&2; return 2; }
  jq -e --arg re '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' '
    def nonempty_strings: type == "array" and length > 0 and all(.[]; type == "string" and length > 0);
    .version == 1 and (.exceptions | type == "array")
    and all(.exceptions[];
      (keys - ["ids", "package", "locations", "variants", "reason", "expires"] | length == 0)
      and (.ids | nonempty_strings) and (.locations | nonempty_strings) and (.variants | nonempty_strings)
      and all(.variants[]; . == "debian" or . == "alpine")
      and (.package | type == "string" and length > 0)
      and (.reason | type == "string" and length >= 20)
      and (.expires | type == "string" and test($re)))' "$file" >/dev/null \
    || { echo "invalid exceptions file $file: expected {version: 1, exceptions: [{ids, package, locations, variants, reason (>=20 chars), expires YYYY-MM-DD}]}" >&2; return 2; }
}

if [ "${1:-}" = "--validate-exceptions" ]; then
  validate_exceptions "${2:?usage: check-vuln-threshold.sh --validate-exceptions FILE}"
  echo "exceptions file OK: $2"
  exit 0
fi

report="${1:?usage: check-vuln-threshold.sh GRYPE_JSON [LABEL]}"
label="${2:-image}"
fail_on="${VULN_FAIL_ON:-critical}"
ignore_unfixed="${VULN_IGNORE_UNFIXED:-false}"
exceptions_file="${VULN_EXCEPTIONS_FILE:-}"
variant="${VULN_VARIANT:-}"

[ -f "$report" ] || { echo "report not found: $report" >&2; exit 2; }
case "$fail_on" in
  none)     blocked='[]' ;;
  critical) blocked='["critical"]' ;;
  high)     blocked='["critical","high"]' ;;
  *) echo "VULN_FAIL_ON must be none|critical|high, got '$fail_on'" >&2; exit 2 ;;
esac
case "$ignore_unfixed" in true|false) ;; *) echo "VULN_IGNORE_UNFIXED must be true|false" >&2; exit 2 ;; esac

# Active exceptions: right variant, not expired. Expired ones are reported.
active='[]'; expired='[]'
if [ -n "$exceptions_file" ]; then
  validate_exceptions "$exceptions_file" || exit 2
  active="$(jq -c --arg v "$variant" --arg today "$today" \
    '[.exceptions[] | select(.expires >= $today) | select(.variants | index($v))]' "$exceptions_file")"
  expired="$(jq -c --arg v "$variant" --arg today "$today" \
    '[.exceptions[] | select(.expires < $today) | select(.variants | index($v))]' "$exceptions_file")"
fi

findings="$(jq -c '[.matches[]? | {
    id: .vulnerability.id,
    sev: (.vulnerability.severity // "unknown" | ascii_downcase),
    fix: (.vulnerability.fix.state // "unknown"),
    fixed_in: ((.vulnerability.fix.versions // []) | join(",")),
    pkg: .artifact.name,
    ver: .artifact.version,
    locs: [.artifact.locations[]?.path]
  }] | group_by([.id, .pkg, .ver]) | map(.[0] + {locs: (map(.locs[]) | unique)})' "$report")"

count() { jq --arg s "$1" '[.[] | select(.sev == $s)] | length' <<<"$findings"; }

# Blocking candidates by severity and fix state, then split off active exceptions.
candidates="$(jq -c --argjson blocked "$blocked" --arg ignore "$ignore_unfixed" \
  '[.[] | select(.sev as $s | $blocked | index($s)) | select($ignore != "true" or .fix == "fixed")]' <<<"$findings")"
# A finding is excepted only if EVERY file it was found in is covered by the same entry.
split="$(jq -c --argjson ex "$active" '
  def covered($f; $e):
    ($e.ids | index($f.id)) != null and $e.package == $f.pkg
    and ($f.locs | length) > 0
    and all($f.locs[]; . as $l | any($e.locations[]; . as $g
          | if ($g | endswith("*")) then ($l | startswith($g[:-1])) else $l == $g end));
  {excepted: [.[] | . as $f | select(any($ex[]; covered($f; .)))
                  | . + {reason: ([$ex[] | select(covered($f; .)) | .reason][0])}],
   blocking: [.[] | . as $f | select(any($ex[]; covered($f; .)) | not)]}' <<<"$candidates")"
blocking="$(jq -c .blocking <<<"$split")"
excepted="$(jq -c .excepted <<<"$split")"
n_blocking="$(jq 'length' <<<"$blocking")"
n_excepted="$(jq 'length' <<<"$excepted")"
n_crit="$(count critical)"; n_high="$(count high)"; n_med="$(count medium)"
n_low="$(count low)"

echo "Vulnerability scan (${label}): critical=${n_crit} high=${n_high} medium=${n_med} low=${n_low}"
echo "Policy: VULN_FAIL_ON=${fail_on} VULN_IGNORE_UNFIXED=${ignore_unfixed} exceptions-applied=${n_excepted}"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### Vulnerability scan: ${label}"
    echo
    echo "| Critical | High | Medium | Low |"
    echo "|---:|---:|---:|---:|"
    echo "| ${n_crit} | ${n_high} | ${n_med} | ${n_low} |"
    echo
    echo "Policy: block on \`${fail_on}\`, ignore unfixed: \`${ignore_unfixed}\`, reviewed exceptions applied: ${n_excepted}."
    echo
  } >> "$GITHUB_STEP_SUMMARY"
fi

list() { # list <json array> <max>
  jq -r --argjson max "$2" '.[:$max][]
    | "  \(.sev | ascii_upcase) \(.id)  \(.pkg) \(.ver)  (fix: \(if .fixed_in == "" then "none" else .fixed_in end))"' <<<"$1"
}

# Expired exceptions no longer apply: say so, the findings below block again.
if [ "$(jq 'length' <<<"$expired")" -gt 0 ]; then
  echo "::warning title=Vulnerability exceptions expired (${label})::$(jq -r '[.[] | "\(.package) (\(.expires))"] | join(", ")' <<<"$expired") - renew (reviewed) or fix; the findings block again."
fi

# Applied exceptions are never silent.
if [ "$n_excepted" -gt 0 ]; then
  echo "::notice title=Reviewed vulnerability exceptions applied (${label})::${n_excepted} finding(s) excepted via ${exceptions_file} (expire: $(jq -r '[.[].expires] | unique | join(", ")' <<<"$active"))."
  jq -r '.[] | "  EXCEPTED \(.sev | ascii_upcase) \(.id)  \(.pkg) \(.ver) in \(.locs | join(", "))"' <<<"$excepted"
  jq -r 'map(.reason) | unique[] | "  reason: \(.)"' <<<"$excepted"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      echo "Excepted (reviewed, time-boxed): ${n_excepted} finding(s)."
      jq -r '.[] | "- \(.id) \(.pkg) \(.ver)"' <<<"$excepted"
      echo
    } >> "$GITHUB_STEP_SUMMARY"
  fi
fi

# High findings that do not block are surfaced as warnings so they stay visible.
if ! jq -e 'index("high")' <<<"$blocked" >/dev/null && [ "$n_high" -gt 0 ]; then
  echo "::warning title=High vulnerabilities (${label})::${n_high} High finding(s), not blocking (VULN_FAIL_ON=${fail_on}). See the scan artifact."
  list "$(jq -c '[.[] | select(.sev == "high")]' <<<"$findings")" 20
fi

if [ "$n_blocking" -gt 0 ]; then
  echo "::error title=Vulnerability threshold exceeded (${label})::${n_blocking} finding(s) at or above '${fail_on}' block this image."
  list "$blocking" 50
  exit 1
fi
echo "Threshold OK."
