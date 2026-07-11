# Failure log

Every failure hit while hardening the platform (Stage 2 exit test) and
running the AI loop (Stage 3). Each entry: what broke, why, what changed.
This log is a deliverable — proof the contract was hardened by contact with
reality, not designed in a vacuum (spec §8, §9).

## Platform-side (Stage 2 exit test: the `ping` deploy)

### 1. Nested reusable workflows resolve `./` against the calling repo
First `ping` run failed at parse time: `deploy.yml@v0.1.0 -->
"./.github/workflows/build-scan-push.yml" : workflow was not found`. When a
reusable workflow is called cross-repo, GitHub resolves its nested local
references against the CALLER's repository. **Fix (v0.1.1):** nested refs are
fully qualified and self-pinned to the release tag; bumping them (plus
template-app's two refs) is a documented release chore in deploy.yml.

### 2. The image gate caught a real CVE in a current official image
Second run: Trivy image gate failed on CVE-2026-33630 (c-ares, HIGH, fix
available) in `nginxinc/nginx-unprivileged:alpine` — a *current* official
image. Base images lag CVE fixes by days. **Fix:** `apk upgrade --no-cache`
in the template Dockerfile; CONVENTIONS.md now states OS-package upgrades as
a rule, not a tip.

### 3. Trivy scans remote Terraform modules
Third run: the app repo's IaC gate followed the `git::` module source and
flagged AWS-0104 (CRITICAL, unrestricted task egress) inside the platform's
own fargate-service module. Deliberate design: tasks reach ECR/logs/deps via
NAT; compensating controls are private subnets, ALB-only ingress, and a
permissionless task role. **Fix (v0.1.2):** documented inline
`#trivy:ignore` exception with justification in the module; egress lockdown
via VPC endpoints is roadmap work.

### 4. Deploy-role IAM: unscopeable list calls and two-resource authorization
Fourth run: apply failed on `logs:DescribeLogGroups` (the provider issues it
unscoped — a list call can't be limited to a name prefix) and
`ec2:AuthorizeSecurityGroup*` (rule actions authorize against BOTH the
tag-guarded security-group AND the untaggable security-group-rule resource,
so a ResourceTag condition can never pass on the latter). **Fix:** separate
statements — list call allowed read-only account-wide; rule-resource half
unconditioned, which stays safe because IAM requires the paired,
tag-guarded security-group resource in the same request.

## Agent-loop (Stage 3: cold agent + spec + CONVENTIONS.md)

### 5. npm's bundled dependencies fail the image gate on node base images
The agent's first push failed the Trivy image gate: 2 HIGH CVEs
(CVE-2026-33671 picomatch, CVE-2026-48815 sigstore) — both inside npm's own
bundled node_modules in `node:22-alpine`, despite the app having zero npm
dependencies. **Agent's own fix, no human help:** `rm -rf` npm/npx/corepack
from the image (the container never invokes them), verified clean with a
local trivy scan, repushed, green. Candidate CONVENTIONS.md addition:
"strip package managers from runtime images."

### 6. Preflight broke on schema-legal env values (v0.2.0 cold rerun)
The rerun agent's `make preflight` failed at health-check: the Makefile
accumulated `-e $k=$v` docker args in an unquoted string, so an env value
with a space (`GREETING: "tasks api"` — perfectly legal per the schema) was
shell-split, and docker parsed a fragment as the image name. The agent
worked around it app-side (space-free value); the real defect was
platform-side. **Fix:** `set -- "$@" -e "$k=$v"` positional-parameter
quoting in the template Makefile, verified against a spacey value. Lesson:
the validation tool must accept everything the schema accepts — anything
narrower is a second, undocumented contract.

## Stage 3 result

Cold Sonnet agent, two documents (APP_SPEC.md + CONVENTIONS.md), template
repo. **Spec handed over 21:32:50 → live verified API 21:41:08 ≈ 8m18s**,
including the failed pipeline iteration and its diagnosis. Goal was < 15
minutes. The agent never touched main.tf or ci.yml, used the manifest env
contract correctly (GREETING), and verified the deployed API against the
spec with curl before reporting done.

## v0.2.0 contract-as-tool rerun (same spec, fresh cold agent, `tasks` app)

Identical protocol against the restructured contract (AGENTS.md index +
docs/ + schema + `make preflight`): **6m38s spec-to-verified-URL, zero CI
failures** (vs 8m18s and one CI failure on the monolith). What changed the
outcome wasn't doc size — the agent read all four docs anyway for a
full-app build — it was `make preflight`: the one failure this run
(entry 6) surfaced locally in seconds instead of costing a ~5-minute CI
round-trip, and the npm-strip lesson encoded in docs/dockerfile.md was
applied proactively instead of being rediscovered. Progressive disclosure
should pay off more on narrow tasks (a config tweak needs one doc, not the
monolith); the measured v0.2.0 wins are local feedback speed and encoded
lessons.
