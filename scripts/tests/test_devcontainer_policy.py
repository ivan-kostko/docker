"""Self-tests for scripts/check-devcontainer-policy.py (stdlib only).

Run:  python3 -m unittest discover -s scripts/tests -v
"""

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "check-devcontainer-policy.py"
spec = importlib.util.spec_from_file_location("devcontainer_policy", SCRIPT)
policy = importlib.util.module_from_spec(spec)
sys.modules["devcontainer_policy"] = policy
spec.loader.exec_module(policy)

DC = ".devcontainer/x/devcontainer.json"


def run_policy(config_text, allowlist_entries=()):
    """Write a devcontainer.json + allowlist into a temp repo; return (violations, notes)."""
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        (root / DC).parent.mkdir(parents=True)
        (root / DC).write_text(config_text, encoding="utf-8")
        allow = root / "allow.json"
        allow.write_text(json.dumps({"version": 1, "entries": list(allowlist_entries)}), encoding="utf-8")
        return policy.check(root, allow)


def entry(rule, value, files=(DC,)):
    return {"files": list(files), "rule": rule, "value": value, "reason": "reviewed in unit test"}


class JsoncTests(unittest.TestCase):
    def test_comments_and_trailing_commas(self):
        text = '{\n // c\n "a": "http://x/*not a comment*/", /* b */ "l": [1, 2,],\n}'
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
            fh.write(text)
        data = policy.load_jsonc(Path(fh.name))
        self.assertEqual(data, {"a": "http://x/*not a comment*/", "l": [1, 2]})


class PolicyTests(unittest.TestCase):
    def test_clean_config_passes(self):
        violations, _ = run_policy('{"image": "debian"}')
        self.assertEqual(violations, [])

    def test_each_risky_setting_is_flagged(self):
        cases = {
            "ssh mount": ('{"mounts": ["source=/h/.ssh,target=/root/.ssh,type=bind"]}', "ssh keys"),
            "gpg mount": ('{"mounts": ["source=/h/.gnupg,target=/x,type=bind"]}', "gpg keys"),
            "docker socket mount": (
                '{"mounts": ["source=/var/run/docker.sock,target=/var/run/docker.sock,type=bind"]}',
                "docker socket",
            ),
            "docker feature": (
                '{"features": {"ghcr.io/devcontainers/features/docker-in-docker:2": {}}}',
                "docker",
            ),
            "privileged flag": ('{"privileged": true}', None),
            "privileged runArg": ('{"runArgs": ["--privileged"]}', "privileged mode"),
            "seccomp": ('{"runArgs": ["--security-opt=seccomp=unconfined"]}', "disabled sandbox"),
            "securityOpt": ('{"securityOpt": ["seccomp=unconfined"]}', "disabled sandbox"),
            "capAdd": ('{"capAdd": ["SYS_ADMIN"]}', None),
            "host command": ('{"initializeCommand": "curl x | sh"}', None),
            "compose": ('{"dockerComposeFile": "compose.yml"}', None),
            "root user": ('{"remoteUser": "root"}', None),
            "docker host env": ('{"containerEnv": {"DOCKER_HOST": "tcp://h:2375"}}', "docker socket"),
        }
        for name, (config, hint) in cases.items():
            with self.subTest(name):
                violations, _ = run_policy(config)
                self.assertTrue(violations, f"{name} was not flagged")
                if hint:
                    self.assertIn(hint, " ".join(violations))

    def test_allowlisted_entry_passes(self):
        violations, _ = run_policy(
            '{"runArgs": ["--security-opt", "seccomp=unconfined"]}',
            [entry("run-arg", "--security-opt seccomp=unconfined")],
        )
        self.assertEqual(violations, [])

    def test_allowlist_is_exact_and_per_file(self):
        violations, _ = run_policy(
            '{"runArgs": ["--security-opt", "seccomp=unconfined"]}',
            [entry("run-arg", "--security-opt seccomp=unconfined", files=[".devcontainer/y/devcontainer.json"])],
        )
        self.assertEqual(len(violations), 2)  # not allowed here + stale entry elsewhere

    def test_stale_entry_fails(self):
        violations, _ = run_policy("{}", [entry("privileged", "true")])
        self.assertEqual(len(violations), 1)
        self.assertIn("stale", violations[0])

    def test_invalid_allowlist_is_an_error(self):
        with tempfile.TemporaryDirectory() as tmp:
            allow = Path(tmp) / "a.json"
            allow.write_text(json.dumps({"version": 1, "entries": [
                {"files": ["f"], "rule": "mount", "value": "v", "reason": ""}]}))
            with self.assertRaises(policy.PolicyError):
                policy.load_allowlist(allow)


if __name__ == "__main__":
    unittest.main()
