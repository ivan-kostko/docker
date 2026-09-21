#!/usr/bin/env bash
# Self-test for scripts/check-vuln-threshold.sh. Run: scripts/tests/test-vuln-threshold.sh
set -euo pipefail

script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/check-vuln-threshold.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# 1 fixed Critical, 1 unfixed Critical, 1 High (duplicated), 1 Low
cat > "$tmp/grype.json" <<'JSON'
{"matches":[
 {"vulnerability":{"id":"CVE-1","severity":"Critical","fix":{"state":"fixed","versions":["1.2"]}},"artifact":{"name":"openssl","version":"1.0"}},
 {"vulnerability":{"id":"CVE-2","severity":"High","fix":{"state":"not-fixed","versions":[]}},"artifact":{"name":"zlib","version":"1"}},
 {"vulnerability":{"id":"CVE-3","severity":"Critical","fix":{"state":"not-fixed","versions":[]}},"artifact":{"name":"glibc","version":"2"}},
 {"vulnerability":{"id":"CVE-2","severity":"High","fix":{"state":"not-fixed","versions":[]}},"artifact":{"name":"zlib","version":"1"}},
 {"vulnerability":{"id":"CVE-4","severity":"Low","fix":{"state":"unknown"}},"artifact":{"name":"x","version":"1"}}
]}
JSON
echo '{"matches":[{"vulnerability":{"id":"CVE-2","severity":"High","fix":{"state":"fixed","versions":["2"]}},"artifact":{"name":"zlib","version":"1"}}]}' > "$tmp/high-only.json"
echo '{"matches":[]}' > "$tmp/empty.json"

failures=0
expect() { # expect <rc> <fail_on> <ignore_unfixed> <report> <description>
  local want="$1" rc=0
  VULN_FAIL_ON="$2" VULN_IGNORE_UNFIXED="$3" "$script" "$4" test >"$tmp/out" 2>&1 || rc=$?
  if [ "$rc" -eq "$want" ]; then echo "ok   $5"; else echo "FAIL $5 (rc=$rc, want $want)"; cat "$tmp/out"; failures=$((failures + 1)); fi
}

expect 1 critical false "$tmp/grype.json"    "critical blocks on Critical"
expect 0 critical true  "$tmp/high-only.json" "critical does not block on High"
expect 1 high     false "$tmp/high-only.json" "high blocks on High"
expect 0 none     false "$tmp/grype.json"     "none never blocks"
expect 0 critical false "$tmp/empty.json"     "no findings passes"
expect 2 bogus    false "$tmp/grype.json"     "invalid VULN_FAIL_ON is an input error"
expect 2 critical false "$tmp/missing.json"   "missing report is an input error"

# Unfixed Criticals are ignored when asked, fixed ones still block.
expect 1 critical true "$tmp/grype.json" "ignore-unfixed still blocks fixed Critical"
jq 'del(.matches[0])' "$tmp/grype.json" > "$tmp/no-fixed.json"
expect 0 critical true "$tmp/no-fixed.json" "ignore-unfixed passes when only unfixed Criticals remain"

# High is surfaced as a non-blocking warning under the default threshold.
out="$(VULN_FAIL_ON=critical "$script" "$tmp/high-only.json" test)"
if grep -q '::warning' <<<"$out"; then
  echo "ok   high reported as warning"
else
  echo "FAIL high warning missing"; failures=$((failures + 1))
fi

# --- reviewed, time-boxed exceptions -----------------------------------------
cat > "$tmp/plugin.json" <<'JSON'
{"matches":[
 {"vulnerability":{"id":"GHSA-x","severity":"Critical","fix":{"state":"fixed","versions":["2"]}},"artifact":{"name":"golang.org/x/crypto","version":"v1","locations":[{"path":"/usr/libexec/docker/cli-plugins/docker-buildx"}]}}
]}
JSON
cat > "$tmp/other-location.json" <<'JSON'
{"matches":[
 {"vulnerability":{"id":"GHSA-x","severity":"Critical","fix":{"state":"fixed","versions":["2"]}},"artifact":{"name":"golang.org/x/crypto","version":"v1","locations":[{"path":"/usr/local/bin/other"}]}},
 {"vulnerability":{"id":"GHSA-x","severity":"Critical","fix":{"state":"fixed","versions":["2"]}},"artifact":{"name":"golang.org/x/crypto","version":"v1","locations":[{"path":"/usr/libexec/docker/cli-plugins/docker-buildx"}]}}
]}
JSON
cat > "$tmp/exceptions.json" <<'JSON'
{"version":1,"exceptions":[{"ids":["GHSA-x"],"package":"golang.org/x/crypto",
 "locations":["/usr/libexec/docker/cli-plugins/*"],"variants":["alpine"],
 "reason":"vendored in distro plugin, fixed upstream, not yet packaged","expires":"2026-11-20"}]}
JSON
expect_ex() { # expect_ex <description> <want-rc> <report> <variant> <today> [exceptions-file]
  local rc=0
  VULN_FAIL_ON=critical VULN_IGNORE_UNFIXED=true VULN_VARIANT="$4" VULN_TODAY="$5" \
    VULN_EXCEPTIONS_FILE="${6:-$tmp/exceptions.json}" "$script" "$3" test >"$tmp/out" 2>&1 || rc=$?
  if [ "$rc" -eq "$2" ]; then echo "ok   $1"; else echo "FAIL $1 (rc=$rc, want $2)"; cat "$tmp/out"; failures=$((failures + 1)); fi
}
expect_ex "exception covers matching finding"              0 "$tmp/plugin.json"         alpine 2026-10-01
expect_ex "exception is listed, never silent"              0 "$tmp/plugin.json"         alpine 2026-10-01
grep -q 'EXCEPTED' "$tmp/out" || { echo "FAIL applied exception not listed"; failures=$((failures + 1)); }
expect_ex "expired exception no longer applies"            1 "$tmp/plugin.json"         alpine 2026-11-21
grep -q 'exceptions expired' "$tmp/out" || { echo "FAIL expiry not reported"; failures=$((failures + 1)); }
expect_ex "exception is per variant"                       1 "$tmp/plugin.json"         debian 2026-10-01
expect_ex "finding also found outside allowed path blocks" 1 "$tmp/other-location.json" alpine 2026-10-01
expect_ex "exception does not cover other vulnerability"   1 "$tmp/grype.json"          alpine 2026-10-01

echo '{"version":1,"exceptions":[{"ids":["x"],"package":"p","locations":["/l"],"variants":["alpine"],"reason":"short","expires":"2026-11-20"}]}' > "$tmp/bad-reason.json"
echo '{"version":1,"exceptions":[{"ids":["x"],"package":"p","locations":["/l"],"variants":["alpine"],"reason":"long enough reason here","expires":"soon"}]}' > "$tmp/bad-date.json"
expect_ex "exception without a real reason is rejected"    2 "$tmp/plugin.json"         alpine 2026-10-01 "$tmp/bad-reason.json"
expect_ex "exception with bad expiry date is rejected"     2 "$tmp/plugin.json"         alpine 2026-10-01 "$tmp/bad-date.json"

# The committed exception list must always be valid.
if "$script" --validate-exceptions "$(cd "$(dirname "$script")/.." && pwd)/.github/vuln-exceptions.json" >/dev/null; then
  echo "ok   committed .github/vuln-exceptions.json is valid"
else
  echo "FAIL committed .github/vuln-exceptions.json is invalid"; failures=$((failures + 1))
fi

exit "$failures"
