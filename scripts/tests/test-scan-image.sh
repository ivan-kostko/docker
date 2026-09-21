#!/usr/bin/env bash
# Self-test for scripts/scan-image.sh using stub syft/grype (no image, network
# or scanner needed): per-platform report directories are kept apart, reports
# are written even when the threshold blocks, and a Critical finding in one
# platform's scan fails that scan (which is what fails the PR verify job).
set -euo pipefail

script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scan-image.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# Stub syft: writes the requested -o outputs, logs its arguments.
cat > "$tmp/syft" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG"
while [ "$#" -gt 0 ]; do
  case "$1" in -o) f="${2#*=}"; echo '{"stub":"sbom"}' > "$f"; shift 2 ;; *) shift ;; esac
done
STUB
# Stub grype: copies STUB_GRYPE_JSON into the json output, writes a sarif stub.
cat > "$tmp/grype" <<'STUB'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) case "$2" in json=*) cp "$STUB_GRYPE_JSON" "${2#json=}" ;; sarif=*) echo '{}' > "${2#sarif=}" ;; esac; shift 2 ;;
    *) shift ;;
  esac
done
STUB
chmod +x "$tmp/syft" "$tmp/grype"
echo '{"matches":[]}' > "$tmp/clean.json"
echo '{"matches":[{"vulnerability":{"id":"CVE-9","severity":"Critical","fix":{"state":"fixed","versions":["2"]}},"artifact":{"name":"libc","version":"1"}}]}' > "$tmp/critical.json"

export SYFT="$tmp/syft" GRYPE="$tmp/grype" STUB_LOG="$tmp/syft.log" VULN_FAIL_ON=critical
failures=0
scan() { # scan <report-json> <out-dir> <platform> -> rc
  STUB_GRYPE_JSON="$1" "$script" "docker-archive:/tmp/product.tar" "$2" "$3" "test $2" >"$tmp/out" 2>&1
}
expect() { # expect <description> <want-rc> <report-json> <out-dir> <platform>
  local rc=0; scan "$3" "$4" "$5" || rc=$?
  if [ "$rc" -eq "$2" ]; then echo "ok   $1"; else echo "FAIL $1 (rc=$rc, want $2)"; cat "$tmp/out"; failures=$((failures + 1)); fi
}

expect "amd64 clean passes"                      0 "$tmp/clean.json"    "$tmp/reports/debian-amd64" ""
expect "arm64 Critical fails the scan"           1 "$tmp/critical.json" "$tmp/reports/debian-arm64" ""
expect "amd64 Critical fails the scan"           1 "$tmp/critical.json" "$tmp/reports/alpine-amd64" ""

for d in debian-amd64 debian-arm64 alpine-amd64; do
  for f in sbom.spdx.json sbom.syft.json grype.json grype.sarif; do
    [ -f "$tmp/reports/$d/$f" ] || { echo "FAIL missing $d/$f"; failures=$((failures + 1)); }
  done
done
echo "ok   reports written per variant/platform, also when the threshold blocks"

# Critical in arm64 must not be masked by a clean amd64 report in another dir.
if grep -q CVE-9 "$tmp/reports/debian-arm64/grype.json" && ! grep -q CVE-9 "$tmp/reports/debian-amd64/grype.json"; then
  echo "ok   per-platform reports do not overwrite each other"
else
  echo "FAIL per-platform reports overwritten"; failures=$((failures + 1))
fi

# --platform is forwarded to syft when given (registry sources need it)
: > "$STUB_LOG"; scan "$tmp/clean.json" "$tmp/reports/registry-arm64" linux/arm64 || true
if grep -q -- '--platform linux/arm64' "$STUB_LOG"; then echo "ok   platform forwarded to syft"; else echo "FAIL platform not forwarded"; failures=$((failures + 1)); fi

exit "$failures"
