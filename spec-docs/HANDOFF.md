# Flightdeck — session handoff (2026-07-12)

Context bundle for continuing this project in a fresh thread. Private working
notes; keep out of anything public (see CLAUDE.local.md — no employer names,
resume/publish/recording framing in committed files, commits, or issues).

## What flightdeck is
A golden-path platform: a plain-language app spec → production-grade AWS
deployment via Terraform + reusable GitHub Actions + an `app-manifest.yaml`
contract. A coding agent (or a human) satisfies the contract; the platform
does build/scan/deploy/serve. Source of truth: `spec-docs/flightdeck-spec.md`
(read §4 non-goals, §5a deploy model, §5b safeguards, §10 decided-log before
changing anything). Repo: github.com/rpuffe/flightdeck (public). Runs in
Robert's existing personal AWS account 076047026061, us-east-1, profile
default, IAM user `agent-infra-tool` (static creds).

## Hard rules (do not violate)
- **AWS safeguards (§5b / CLAUDE.local.md):** net-new resources only; NEVER
  destroy/modify/import pre-existing resources. `flightdeck-` name prefix +
  `project=flightdeck` default tags on everything. Destroy = terraform destroy
  against flightdeck's own state only, never tag/account-wide scripts. Parent
  DNS zone robertpuffe.com (Z0308795E9NPDUEE9Y91) is DATA-SOURCE-ONLY except the
  one NS delegation record for fd.robertpuffe.com. Other hosted zones off-limits.
- **First apply of a NEW stack: Robert runs it.** Subsequent applies + all make
  targets: agent may run directly (authorized 2026-07-10).
- **No performative content** in committed files/commits/issues (employer names,
  resume, linkedin, publish, recording/video). Robert tracks those privately.
- **Accounts:** GitHub = rpuffe (NOT the Eldermark work acct in the gh keyring).
  Verify `gh api user` before repo ops.
- **Subagents whenever possible** — build/review/test/research. Sonnet for
  code/review/test, Haiku for mechanical. Orchestrator keeps only orchestration,
  sensitive applies, commits, judgment calls. Pattern used all session:
  build agent → review agent (skeptical, finds real bugs) → fix agent → my
  apply → live-test agent.
- **Toolchain:** GNU Make 3.81 (no 4.x features). Docker Desktop often off —
  start before builds. Terraform 1.13.
- **Create GitHub issues as we go** for anything that needs doing; close with a
  comment when done.
- **Release chore (every version tag, all in the tagged commit):** bump @refs in
  `.github/workflows/deploy.yml` + `promote.yml`, template-app `ci.yml` refs +
  `main.tf ?ref=`, and write the tag into `template-app/.flightdeck-version`.

## Architecture (current, platform tag v0.5.0)
- `bootstrap/` — account-level stack (S3 state backend w/ native lockfile; GitHub
  OIDC provider + `flightdeck-deploy` role; VPC + fck-nat t4g.nano; ECR
  repo-per-app; DNS child zone fd.robertpuffe.com + wildcard ACM; shared ALB w/
  HTTPS + default 404; budget alarm $30/mo; `scaler.tf` + `lambda/scaler.py`).
- `modules/fargate-service/` — the flagship module: one Fargate service behind
  the shared ALB, host-based listener rule, target group, logs, 2 alarms,
  permissionless task role (unless storage). `environment` var (dev/prod);
  optional `storage` var (s3). Name regex `^[a-z][a-z0-9-]{0,15}$` (16 char cap
  for the -dev suffix). "wake" is a reserved name.
- `.github/workflows/` — reusable: build-scan-push (Trivy image gate), 
  terraform-plan-apply (Trivy IaC gate, env-aware state keys), deploy (main→dev),
  promote (tag v*→prod, same image), pr-checks (credential-free).
- `template-app/` — what an app repo starts as: AGENTS.md+CLAUDE.md (thin index),
  docs/ (contract/dockerfile/pipeline/example), app-manifest.yaml +
  .schema.json, Makefile (preflight/upgrade/run/test), main.tf (pinned ?ref),
  ci.yml, Dockerfile placeholder, test.sh, .flightdeck-version.

## The contract / pipeline
- Manifest fields (v1 final + additions): name, port, healthcheck, cpu, memory,
  env, and optional `storage: s3`. `image` is deliberately NOT a field (CI
  computes it). STORAGE_BUCKET is a reserved env key.
- Triggers: PR → credential-free checks (OIDC trust excludes PR refs). Push to
  main → dev at `https://<name>-dev.fd.robertpuffe.com` (state apps/<name>/dev/).
  Tag v* → prod at `https://<name>.fd.robertpuffe.com` — promotes the SAME
  immutable SHA image main built (state apps/<name>/terraform.tfstate, legacy
  key). Build once, promote the artifact.
- `make preflight` mirrors CI's gates locally (validate/build/healthcheck/Trivy)
  and warns on version drift. `make upgrade [TAG=]` replaces every platform-owned
  file from the release tarball (refs bump as a side effect) — refuses over
  uncommitted platform paths, never commits. `make new-app NAME=x` scaffolds +
  registers. Scale ops: `make ps / stop SVC= / start SVC= / stop-all / start-all`
  (route through the scaler Lambda; deliberate desired-count drift, next deploy
  restores).

## Live apps (state varies — nightly cooldown at 23:30 America/Chicago)
todo, tasks, board (+board-dev), golf (golf-dev — Robert's 3-hole mini golf,
storage: s3 available, not yet wired for high scores), ping (Stage-2 exit test).
hello was destroyed as the teardown proof. All at <name>.fd.robertpuffe.com.
Status dashboard: https://wake.fd.robertpuffe.com/ .

## Fleet scaler (bootstrap/scaler.tf + lambda/scaler.py)
One Lambda `flightdeck-scaler`, invoked 3 ways: EventBridge Scheduler (nightly
stop-all 23:30 Central), ALB wake endpoint wake.fd (status dashboard + ?svc=
start-on-demand, START-ONLY), and direct invoke from make stop/start (operator
granted via a RESOURCE-BASED policy ON the Lambda — aws_lambda_permission
`operator_invoke`, principal = caller ARN — NOT a policy on the pre-existing
user; §5b-clean). Account Lambda concurrency quota ~10 blocks reserved-
concurrency caps (#33).

## THE OPEN BUG (top priority next session): auto-wake deadlock — issue #35
Auto-wake-on-direct-visit was built and SHELVED same night. The rule-flip
approach deadlocks: stopping flipped an app's ALB rule to the scaler TG, which
detaches the app's own TG; ALB only health-checks ATTACHED target groups, so the
flip-back-when-healthy condition never fires → infinite warming loop; every stop
stranded another app (had to manually restore 5). SAFETY REVERT applied (commit
8d6d99d): stop path no longer flips; flip helpers + `_handle_app_host` left
DORMANT/SHELVED in scaler.py. A directly-visited sleeping app now returns ALB
503 (pre-feature behavior). Redesign options in #35: (1) Lambda in VPC directly
probing task health [most correct], (2) flip-on-ECS-running + fast TG health
check + tuned warming-refresh [pragmatic], (3) Lambda-as-proxy, no flip. LESSON:
live-test stateful ALB/health features end-to-end (stop→visit→recover→verify
rule flipped back) — unit tests + design review can't see ALB's attached-only
health-check behavior.

## Open issues
- #35 auto-wake deadlock redesign (TOP — see above)
- #32 scale-from-zero umbrella (superseded-in-detail by #35)
- #33 restore scaler reserved-concurrency after a Lambda quota increase
- #18 / #19 Stage 4: same spec through Cursor + one other agent → README pass/fail
  table (needs Robert's tools; runbook at spec-docs/stage4-runbook.md)
- #30 Stage 5 exit: cold-reader test of the README

## Key files to read first in a new thread
spec-docs/flightdeck-spec.md, spec-docs/failure-log.md (9 numbered entries + run
results — the hardening story), this file, bootstrap/scaler.tf +
bootstrap/lambda/scaler.py (for #35), CLAUDE.md (commands + conventions).
Memory: ~/.claude/.../memory/flightdeck-project-decisions.md has the full
decided-log.

## Cost posture
Idle floor ~$19/mo (ALB + fck-nat). Each running task ~$9/mo; dev+prod doubles.
Budget alarm $30/mo. Nightly cooldown + make stop-all keep it down; deploys and
wake re-warm.
