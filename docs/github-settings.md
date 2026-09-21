# Required GitHub-side settings

Repository files cannot enforce these; without them the CI controls are advisory. Settings → Rules (or Branches /
Environments) unless noted. Replace `master` if the default branch changes.

## 1. Protected default branch (ruleset or branch protection on `master`)

- Require a pull request before merging; **1+ approving review**; dismiss stale approvals on new commits.
- **Require review from Code Owners** ([`.github/CODEOWNERS`](../.github/CODEOWNERS): `.github/`, `dev-base/`,
  `.devcontainer/`, plus `scripts/` and `.pre-commit-config.yaml`, which police them).
- Require status checks to pass, and require branches to be up to date:
  - **`CI gate`** (aggregates `resolve`, `policy` and both `verify` jobs; stable name, works with matrix jobs)
  - optionally also `Policy and quality`
- Block force pushes and deletions; do not allow bypass except for a break-glass admin role.
- Optional: require signed commits (the devcontainer already signs).

Solo-maintainer note: GitHub does not let an author approve their own PR, so "Require review from Code Owners" blocks a
single-owner repository. Add a second code owner/reviewer, or grant one deliberate bypass, rather than dropping the rule.

## 2. Protected release tags

Tag ruleset for `v*`: restrict creation to maintainers, block updates and deletions. A `v*.*.*` tag push publishes.

## 3. `production` environment (Settings → Environments)

The `publish` jobs run in it; it is the approval gate for anything that writes to GHCR.
- **Deployment branches and tags**: selected only → `master` and `v*`.
- **Required reviewers**: at least one maintainer; enable "prevent self-review" if there is more than one. Note this
  gates every publish: pushes to the default branch, release tags, and manual runs (`workflow_dispatch` with
  `publish: true`, the "approved manual release"). The weekly schedule does not publish, so it needs no approval.
  Removing the reviewers removes the gate.
- No environment secrets are needed (only `GITHUB_TOKEN` and OIDC are used).

## 4. Actions settings (Settings → Actions → General)

- Workflow permissions: **read repository contents** by default; leave "Allow GitHub Actions to create and approve
  pull requests" off.
- Fork pull requests: require approval for all outside contributors. Never switch the workflow to
  `pull_request_target`.
- Allowed actions: restrict to GitHub and verified/explicitly listed creators (`docker/*`) and enable
  **Require actions to be pinned to a full-length commit SHA** (all actions in `ci.yml` already are).

## 5. Security features (Settings → Code security)

Dependabot alerts + security updates; secret scanning + push protection; code scanning enabled so the SARIF upload
from `publish` shows up (free for public repositories).

## 6. Package (GHCR)

After the first publish, make sure the `dev-base` package is linked to this repository and that the repository has
**write** access under Package settings → Manage Actions access. Set visibility to public if images should be
pullable without login.

## 7. Optional repository variables

`VULN_FAIL_ON` (`none|critical|high`, default `critical`) and `VULN_IGNORE_UNFIXED` (`true|false`, default `false`);
see [ci-cd.md](ci-cd.md#vulnerability-release-threshold).
