#!/usr/bin/env bash
# Apply the release threshold to a Grype JSON report.
#
# Usage: check-vuln-threshold.sh GRYPE_JSON [LABEL]
#
# Environment (configurable; set as repository variables in CI):
#   VULN_FAIL_ON          none | critical | high     (default: critical)
#       critical  block on Critical, report High without blocking   <- default
#       high      block on Critical and High
#       none      never block; report only
#   VULN_IGNORE_UNFIXED   true | false               (default: false)
#       true: findings without an available fix never block (they are still
#       reported). Useful when a base image carries unfixable CVEs.
#
# Exit: 0 pass, 1 blocked by threshold, 2 usage/input error.
set -euo pipefail

report="${1:?usage: check-vuln-threshold.sh GRYPE_JSON [LABEL]}"
label="${2:-image}"
fail_on="${VULN_FAIL_ON:-critical}"
ignore_unfixed="${VULN_IGNORE_UNFIXED:-false}"

[ -f "$report" ] || { echo "report not found: $report" >&2; exit 2; }
case "$fail_on" in
  none)     blocked='[]' ;;
  critical) blocked='["critical"]' ;;
  high)     blocked='["critical","high"]' ;;
  *) echo "VULN_FAIL_ON must be none|critical|high, got '$fail_on'" >&2; exit 2 ;;
esac
case "$ignore_unfixed" in true|false) ;; *) echo "VULN_IGNORE_UNFIXED must be true|false" >&2; exit 2 ;; esac

findings="$(jq -c '[.matches[]? | {
    id: .vulnerability.id,
    sev: (.vulnerability.severity // "unknown" | ascii_downcase),
    fix: (.vulnerability.fix.state // "unknown"),
    fixed_in: ((.vulnerability.fix.versions // []) | join(",")),
    pkg: .artifact.name,
    ver: .artifact.version
  }] | unique_by([.id, .pkg, .ver])' "$report")"

count() { jq --arg s "$1" '[.[] | select(.sev == $s)] | length' <<<"$findings"; }
blocking="$(jq -c --argjson blocked "$blocked" --arg ignore "$ignore_unfixed" \
  '[.[] | select(.sev as $s | $blocked | index($s)) | select($ignore != "true" or .fix == "fixed")]' <<<"$findings")"
n_blocking="$(jq 'length' <<<"$blocking")"
n_crit="$(count critical)"; n_high="$(count high)"; n_med="$(count medium)"
n_low="$(count low)"

echo "Vulnerability scan (${label}): critical=${n_crit} high=${n_high} medium=${n_med} low=${n_low}"
echo "Policy: VULN_FAIL_ON=${fail_on} VULN_IGNORE_UNFIXED=${ignore_unfixed}"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### Vulnerability scan: ${label}"
    echo
    echo "| Critical | High | Medium | Low |"
    echo "|---:|---:|---:|---:|"
    echo "| ${n_crit} | ${n_high} | ${n_med} | ${n_low} |"
    echo
    echo "Policy: block on \`${fail_on}\`, ignore unfixed: \`${ignore_unfixed}\`."
    echo
  } >> "$GITHUB_STEP_SUMMARY"
fi

list() { # list <json array> <max>
  jq -r --argjson max "$2" '.[:$max][]
    | "  \(.sev | ascii_upcase) \(.id)  \(.pkg) \(.ver)  (fix: \(if .fixed_in == "" then "none" else .fixed_in end))"' <<<"$1"
}

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
