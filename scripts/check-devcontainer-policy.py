#!/usr/bin/env python3
"""Fail if a devcontainer.json introduces a trust-boundary change that has not
been reviewed and recorded in .devcontainer/policy-allowlist.json.

Every risky setting found in a devcontainer.json is turned into a finding
``(file, rule, value)``. A finding passes only when the allowlist has an
entry with the exact same rule and value for that file. The check is
default-deny for the rules below, and it also fails on allowlist entries that
no longer match anything, so the allowlist can not silently grow stale.

Rules (see docs/devcontainer-policy.md for the rationale):

  mount         any entry of "mounts"
  run-arg       any entry of "runArgs" (canonicalised to "--flag value")
  build-option  any entry of "build.options"
  security-opt  any entry of "securityOpt"
  cap-add       any entry of "capAdd"
  privileged    "privileged": true
  feature       any entry of "features"
  host-command  "initializeCommand" (runs on the HOST, outside the container)
  compose       "dockerComposeFile" (arbitrary service definitions)
  docker-socket any string mentioning docker.sock / DOCKER_HOST
  root-user     containerUser/remoteUser set to root

devcontainer.json is JSONC (comments, trailing commas), so a small tolerant
parser is included rather than requiring a third-party dependency.

Usage: check-devcontainer-policy.py [--root DIR] [--allowlist FILE]
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path

DEFAULT_ALLOWLIST = ".devcontainer/policy-allowlist.json"
DEVCONTAINER_GLOBS = (".devcontainer.json", ".devcontainer/**/devcontainer.json")

RULES = {
    "mount": "host path or volume mounted into the container",
    "run-arg": "raw `docker run` argument",
    "build-option": "raw `docker build` option",
    "security-opt": "container security option",
    "cap-add": "extra Linux capability",
    "privileged": "privileged container",
    "feature": "devcontainer feature (can add mounts, privileges and packages)",
    "host-command": "command executed on the host before the container starts",
    "compose": "docker compose based devcontainer",
    "docker-socket": "reference to the Docker socket / remote Docker daemon",
    "root-user": "container or remote user is root",
}

# Patterns that mark a finding as sensitive; only used to make the failure
# message explicit about *why* a reviewer should care.
SENSITIVE = (
    ("ssh keys", re.compile(r"(^|[/\\=])\.ssh([/\\,]|$)|ssh-agent|SSH_AUTH_SOCK", re.I)),
    ("gpg keys", re.compile(r"\.gnupg|gpg-agent|S\.gpg", re.I)),
    ("docker socket / external docker access",
     re.compile(r"docker\.sock|DOCKER_HOST|docker-(outside-of|from|in)-docker", re.I)),
    ("privileged mode", re.compile(r"--privileged|--cap-add|--device|--pid[= ]host|"
                                   r"--net(work)?[= ]host|--ipc[= ]host|--userns", re.I)),
    ("disabled sandbox", re.compile(r"(seccomp|apparmor|label)[=:]\s*(unconfined|disable)", re.I)),
    ("AI agent credentials / config", re.compile(r"[/\\]\.(claude|codex)(\.json)?([/\\,]|$)", re.I)),
    ("cloud / cluster credentials",
     re.compile(r"\.aws|\.kube|\.azure|gcloud|\.docker[/\\]config|\.netrc|\.git-credentials", re.I)),
    ("host filesystem root or home", re.compile(r"source=(/|~|\$\{localEnv:(HOME|USERPROFILE)\})(,|$)", re.I)),
)

DOCKER_SOCKET_RE = re.compile(r"docker\.sock|/var/run/docker|DOCKER_HOST", re.I)


class PolicyError(Exception):
    """Configuration problem (as opposed to a policy violation)."""


@dataclass(frozen=True)
class Finding:
    file: str
    rule: str
    value: str

    @property
    def key(self) -> tuple[str, str, str]:
        return (self.file, self.rule, self.value)

    def sensitivity(self) -> list[str]:
        return [label for label, rx in SENSITIVE if rx.search(self.value)]


# --------------------------------------------------------------------------
# JSONC parsing
# --------------------------------------------------------------------------

def _strip_comments(text: str) -> str:
    out: list[str] = []
    i, n = 0, len(text)
    in_str = False
    while i < n:
        c = text[i]
        if in_str:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(text[i + 1])
                i += 1
            elif c == '"':
                in_str = False
        elif c == '"':
            in_str = True
            out.append(c)
        elif text.startswith("//", i):
            while i < n and text[i] != "\n":
                i += 1
            continue
        elif text.startswith("/*", i):
            end = text.find("*/", i + 2)
            if end == -1:
                raise PolicyError("unterminated /* comment")
            i = end + 2
            continue
        else:
            out.append(c)
        i += 1
    return "".join(out)


def _strip_trailing_commas(text: str) -> str:
    out: list[str] = []
    in_str = False
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if in_str:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(text[i + 1])
                i += 1
            elif c == '"':
                in_str = False
        elif c == '"':
            in_str = True
            out.append(c)
        elif c == ",":
            j = i + 1
            while j < n and text[j] in " \t\r\n":
                j += 1
            if j < n and text[j] in "]}":
                i += 1
                continue
            out.append(c)
        else:
            out.append(c)
        i += 1
    return "".join(out)


def load_jsonc(path: Path):
    try:
        return json.loads(_strip_trailing_commas(_strip_comments(path.read_text(encoding="utf-8"))))
    except (json.JSONDecodeError, PolicyError) as exc:
        raise PolicyError(f"{path}: cannot parse as JSONC: {exc}") from exc


# --------------------------------------------------------------------------
# Finding extraction
# --------------------------------------------------------------------------

def canonical_run_args(args: list) -> list[str]:
    """['--security-opt', 'x'] and ['--security-opt=x'] both become '--security-opt x'."""
    result: list[str] = []
    i = 0
    while i < len(args):
        tok = str(args[i])
        if tok.startswith("-") and "=" in tok:
            flag, value = tok.split("=", 1)
            result.append(f"{flag} {value}")
        elif tok.startswith("-") and i + 1 < len(args) and not str(args[i + 1]).startswith("-"):
            result.append(f"{tok} {args[i + 1]}")
            i += 1
        else:
            result.append(tok)
        i += 1
    return result


def canonical_mount(mount) -> str:
    if isinstance(mount, str):
        return mount.strip()
    if isinstance(mount, dict):
        return ",".join(f"{k}={mount[k]}" for k in sorted(mount))
    raise PolicyError(f"unsupported mount entry: {mount!r}")


def _as_list(value, what: str) -> list:
    if value is None:
        return []
    if not isinstance(value, list):
        raise PolicyError(f"{what} must be a list")
    return value


def _walk_strings(node):
    if isinstance(node, str):
        yield node
    elif isinstance(node, dict):
        for k, v in node.items():
            yield from _walk_strings(k)
            yield from _walk_strings(v)
    elif isinstance(node, list):
        for v in node:
            yield from _walk_strings(v)


def extract_findings(rel: str, cfg: dict) -> list[Finding]:
    if not isinstance(cfg, dict):
        raise PolicyError(f"{rel}: top level must be an object")
    found: list[Finding] = []

    def add(rule: str, value: str) -> None:
        found.append(Finding(rel, rule, value))

    for m in _as_list(cfg.get("mounts"), "mounts"):
        add("mount", canonical_mount(m))
    for a in canonical_run_args(_as_list(cfg.get("runArgs"), "runArgs")):
        add("run-arg", a)
    build = cfg.get("build") or {}
    if isinstance(build, dict):
        for a in canonical_run_args(_as_list(build.get("options"), "build.options")):
            add("build-option", a)
    for s in _as_list(cfg.get("securityOpt"), "securityOpt"):
        add("security-opt", str(s))
    for c in _as_list(cfg.get("capAdd"), "capAdd"):
        add("cap-add", str(c))
    if cfg.get("privileged") is True:
        add("privileged", "true")
    features = cfg.get("features") or {}
    if not isinstance(features, dict):
        raise PolicyError(f"{rel}: features must be an object")
    for feature_id in features:
        add("feature", feature_id)
    init = cfg.get("initializeCommand")
    if init is not None:
        add("host-command", init if isinstance(init, str) else json.dumps(init, sort_keys=True))
    if cfg.get("dockerComposeFile") is not None:
        add("compose", json.dumps(cfg["dockerComposeFile"], sort_keys=True))
    for key in ("containerUser", "remoteUser"):
        if str(cfg.get(key, "")).strip() in ("root", "0"):
            add("root-user", f"{key}=root")

    # Belt and braces: the socket can be reached through mounts, runArgs,
    # env vars, lifecycle commands, ... so scan every string in the file.
    for s in _walk_strings(cfg):
        if DOCKER_SOCKET_RE.search(s):
            add("docker-socket", s.strip())
    return found


# --------------------------------------------------------------------------
# Allowlist
# --------------------------------------------------------------------------

def load_allowlist(path: Path) -> list[dict]:
    if not path.is_file():
        raise PolicyError(f"allowlist not found: {path}")
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise PolicyError(f"{path}: invalid JSON: {exc}") from exc
    if data.get("version") != 1 or not isinstance(data.get("entries"), list):
        raise PolicyError(f'{path}: expected {{"version": 1, "entries": [...]}}')
    for n, entry in enumerate(data["entries"], 1):
        where = f"{path}: entry #{n}"
        unknown = set(entry) - {"files", "rule", "value", "reason"}
        if unknown:
            raise PolicyError(f"{where}: unknown keys {sorted(unknown)}")
        if entry.get("rule") not in RULES:
            raise PolicyError(f"{where}: rule must be one of {sorted(RULES)}")
        if not isinstance(entry.get("value"), str) or not entry["value"]:
            raise PolicyError(f"{where}: value must be a non-empty string")
        files = entry.get("files")
        if not isinstance(files, list) or not files or not all(isinstance(f, str) for f in files):
            raise PolicyError(f"{where}: files must be a non-empty list of paths")
        if not isinstance(entry.get("reason"), str) or len(entry["reason"].strip()) < 10:
            raise PolicyError(f"{where}: a meaningful reason is required")
    return data["entries"]


def discover(root: Path) -> list[Path]:
    seen: dict[str, Path] = {}
    for pattern in DEVCONTAINER_GLOBS:
        for p in root.glob(pattern):
            if p.is_file():
                seen[p.relative_to(root).as_posix()] = p
    return [seen[k] for k in sorted(seen)]


def check(root: Path, allowlist_path: Path) -> tuple[list[str], list[str]]:
    """Return (violations, notes)."""
    entries = load_allowlist(allowlist_path)
    allowed = {}
    for e in entries:
        for f in e["files"]:
            allowed[(f, e["rule"], e["value"])] = e

    violations: list[str] = []
    notes: list[str] = []
    files = discover(root)
    if not files:
        notes.append("no devcontainer.json found; nothing to check")
    used: set[tuple[str, str, str]] = set()
    for path in files:
        rel = path.relative_to(root).as_posix()
        for finding in extract_findings(rel, load_jsonc(path)):
            if finding.key in allowed:
                used.add(finding.key)
                continue
            tags = finding.sensitivity()
            flag = f" [sensitive: {', '.join(tags)}]" if tags else ""
            violations.append(
                f"{rel}: {finding.rule} not in allowlist{flag}\n"
                f"    {finding.value}\n"
                f"    ({RULES[finding.rule]})"
            )
    for key, entry in allowed.items():
        if key in used:
            continue
        violations.append(
            f"{allowlist_path.as_posix()}: stale allowlist entry, no longer present in "
            f"{key[0]}: {key[1]} {key[2]!r} - remove it"
        )
    return violations, notes


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--allowlist", type=Path, default=None,
                        help=f"default: <root>/{DEFAULT_ALLOWLIST}")
    args = parser.parse_args(argv)
    root = args.root.resolve()
    allowlist = args.allowlist or root / DEFAULT_ALLOWLIST

    try:
        violations, notes = check(root, allowlist)
    except PolicyError as exc:
        print(f"devcontainer-policy: error: {exc}", file=sys.stderr)
        return 2
    for note in notes:
        print(f"devcontainer-policy: {note}")
    if violations:
        print("devcontainer-policy: FAILED\n", file=sys.stderr)
        for v in violations:
            print(f"  - {v}", file=sys.stderr)
        print(
            "\nEach setting above widens what code inside the dev container can reach on the\n"
            "developer's machine. If the change is intended, add an entry (with a reason) to\n"
            f"{DEFAULT_ALLOWLIST}; it needs CODEOWNERS review. See docs/devcontainer-policy.md.",
            file=sys.stderr,
        )
        return 1
    print("devcontainer-policy: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
