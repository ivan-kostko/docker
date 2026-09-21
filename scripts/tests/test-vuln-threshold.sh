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

exit "$failures"
