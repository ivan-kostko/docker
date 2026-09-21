#!/usr/bin/env bash
# Self-test for scripts/report-drift.sh (no registry access needed).
set -euo pipefail

script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/report-drift.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
p="io.github.ivan-kostko.dev-base"
cat > "$tmp/labels.json" <<JSON
{"${p}.claude-code-version":"1.0.0","${p}.codex-version":"0.1.0",
 "${p}.oh-my-zsh-revision":"aaa","${p}.powerlevel10k-revision":"bbb",
 "org.opencontainers.image.base.digest":"sha256:base"}
JSON
export PUBLISHED_LABELS_FILE="$tmp/labels.json" IMAGE=ghcr.io/o/dev-base
export CLAUDE_CODE_VERSION=1.0.0 CODEX_VERSION=0.1.0 OMZ_REVISION=aaa P10K_REVISION=bbb BASE_DIGEST=sha256:base

failures=0
check() { # check <description> <expected-rc> <expected-output-grep|-> <env...>
  local desc="$1" want="$2" pat="$3" rc=0 out; shift 3
  out="$(env "$@" "$script" debian 2>&1)" || rc=$?
  if [ "$rc" -eq "$want" ] && { [ "$pat" = "-" ] || grep -q -- "$pat" <<<"$out"; }; then echo "ok   $desc"
  else echo "FAIL $desc (rc=$rc)"; echo "$out"; failures=$((failures + 1)); fi
}

check "no drift -> 0, all same"           0 "same"                       DRIFT_FAIL=1
check "codex drift is reported"           0 "::warning.*Codex"           CODEX_VERSION=0.2.0
check "drift with DRIFT_FAIL=1 -> 1"      1 "DRIFT"                      CODEX_VERSION=0.2.0 DRIFT_FAIL=1
check "base digest drift is reported"     0 "::warning.*Base image"      BASE_DIGEST=sha256:new
check "missing label is flagged unknown"  0 "unknown"                    P10K_REVISION=bbb "PUBLISHED_LABELS_FILE=/dev/null"
exit "$failures"
