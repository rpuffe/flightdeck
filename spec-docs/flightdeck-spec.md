# Flightdeck — Production-Shaped Golden Path for AI-Generated Apps

**Name:** flightdeck (rename is cheap if needed later — decided, don't revisit)
**Owner:** Robert
**Status:** Draft v1
**Timebox:** Demo-able v1 in 2 weekends. Writeup by end of weekend 3.

---

## 1. One-liner

A minimal golden path on AWS — Terraform modules, reusable GitHub Actions, and a
manifest contract — so that an AI coding agent can take a plain-language spec to a
production-minded deployment with guardrails, in minutes, without touching
infrastructure. `prod` is a promotion target, not a production-readiness claim;
the explicit trust boundaries and accepted risks live in the
[threat model](threat-model.md).

## 2. Problem

AI coding agents generate application code fast, but that code lands in a vacuum:
no pipeline, no infra, no guardrails. Platform maturity is the bottleneck, not code
generation. This project encodes infrastructure opinions into a contract that both
humans and agents can satisfy, making deployment a property of the platform rather
than a per-app project.

## 3. Goals

1. **Idea → running URL in under 15 minutes** using a coding agent + this platform.
2. Compliant-by-default pipeline: image scan, IaC scan, OIDC auth (no long-lived keys).
3. A manifest contract (`app-manifest.yaml`) any conforming app can satisfy.
4. An agent-facing contract a coding agent consumes as context (v0.2.0 shape:
   thin `AGENTS.md` index + task-scoped docs + machine-checkable schema +
   `make preflight` — see §7).
5. Clean teardown: `make destroy` leaves nothing behind. Budget alarm from day one.
6. A high-quality README and architecture diagram.

## 3a. Presentation quality (binding tiebreaker)

This repo is written for external readers, not just its author. When two
approaches are otherwise equal, pick the one that reads better to an engineer
encountering the project cold:

- **Visible judgment over visible effort.** Documented tradeoffs (fck-nat vs
  NAT Gateway, no-CLI, no-k8s), the non-goals section, and "what I deliberately
  didn't build" say more than feature count does.
- **Process evidence in the artifact itself.** Closed milestones, issue history,
  and commit messages are part of the record — write them like someone will
  read them, because someone will.
- **Claims demonstrated, not asserted.** Timing claims get measured; the
  clean-teardown claim gets a destroy log; each security default (OIDC, scan
  gates, least-privilege task roles) gets one README sentence on *why*, not
  just *that*.
- **Cost-consciousness as an engineering trait.** The budget alarm and the
  idle-cost metric are talking points, not chores — surface them in the README.
- **A 5-minute path to belief.** A reader should get the point from the README
  alone, without cloning anything.

What this lens does NOT do: add scope. Presentation-driven feature creep is
still creep — new ideas go to §11. The lens only shapes how existing work is
built, documented, and presented.

## 4. Non-goals (v1)

- No CLI yet, but maybe in the future. Interface is Makefile + standard tools (terraform, gh, docker).
- No portal / UI / service catalog. This is one golden path, not an IDP.
- No Kubernetes. ECS/Fargate only.
- No multi-language build matrix. Containerized web service; if it builds a Docker
  image and answers a health check, it qualifies.
- No escape hatches. Deviate from the path = you're off the platform. Deliberate.
- No day-2 operations (upgrades, dashboards beyond basic alarms). Named future
  work. (App-upgrade tooling graduated in v0.5.0 by owner decision — see §10;
  the rest of day-2 stays parked.)

## 5. Architecture

Two Terraform layers, mirroring the account/service split (lesson from operating
AWS Copilot in production):

```
repo: flightdeck (github.com/rpuffe/flightdeck, public)
├── bootstrap/            # account-level, applied once
│   ├── state backend (S3, native lockfile — TF >= 1.10)
│   ├── GitHub OIDC provider + per-app deploy roles
│   ├── ECR dev/prod repos per app via for_each
│   ├── VPC + networking (official module; fck-nat for cost)
│   ├── DNS: child hosted zone fd.robertpuffe.com, delegated from the
│   │   existing robertpuffe.com zone (parent zone is DATA SOURCE ONLY;
│   │   the single NS delegation record is the only write to it)
│   ├── ACM wildcard cert *.fd.robertpuffe.com (DNS-validated in child zone)
│   └── budget alarm
├── modules/
│   └── fargate-service/  # THE flagship module, hand-rolled
│       ├── ECS service + task def (driven by app-manifest values)
│       ├── ALB listener rule + target group + health check
│       ├── CloudWatch logs + basic alarms
│       └── IAM task role (least privilege)
├── .github/workflows/    # reusable workflows apps inherit
│   ├── build-scan-push.yml   (docker build, Trivy image scan, push to ECR)
│   ├── terraform-plan-apply.yml  (fmt, validate, Trivy IaC scan, plan, apply)
│   └── deploy.yml            (calls the above; triggered on merge to main)
├── template-app/         # GitHub template repo contents
│   ├── AGENTS.md + CLAUDE.md      # thin always-in-context index (~20 lines)
│   ├── app-manifest.yaml
│   ├── app-manifest.schema.json   # manifest rules, machine-checkable
│   ├── Makefile                   # make preflight: CI's gates, locally
│   ├── docs/                      # task-scoped contract docs, read on demand
│   ├── Dockerfile                 # placeholder, agent replaces
│   └── .github/workflows/ci.yml   # thin caller of reusable workflows
└── Makefile              # bootstrap / deploy / destroy / demo targets
```

### 5a. App deploy model (decided 2026-07-10)

Copilot-style, minus the CLI: the platform lives in the flightdeck repo and
apps **import** it by pinned version refs. A conforming app repo contains,
in total:

```
app-a/
├── src/ + Dockerfile        # the agent writes this
├── app-manifest.yaml        # the contract — only file with app-specific infra facts
├── main.tf                  # ~15 lines of boilerplate from template-app. NEVER edited.
│                            # yamldecode()s the manifest → fargate-service module
│                            # pinned by git ref (…//modules/fargate-service?ref=v0.1.0)
└── .github/workflows/ci.yml # thin caller: uses rpuffe/flightdeck/...@v0.1.0
```

- State: per-app keys in the shared bootstrap bucket, injected by the reusable
  workflow at init time (`terraform init -backend-config="key=apps/<name>/tfstate"`).
  Backend config never appears in app repos.
- Upgrades: platform ships as tags; apps adopt by bumping two refs.
- Rejected: manifest-only app repos (workflow generates TF at deploy time).
  That recreates Copilot's hidden-codegen liability; 15 visible boilerplate
  lines is the price of standard-tools debuggability.

### 5b. Existing-account safeguards (binding conventions)

Runs in Robert's existing personal AWS account (us-east-1), so:

1. **No imports, ever.** Flightdeck TF only creates net-new resources; it never
   imports or adopts pre-existing ones.
2. **Prefix + tags everywhere:** `flightdeck-` name prefix and
   `project = flightdeck` default tags on every resource.
3. **Destroy is scoped to state, not the account.** `make destroy` =
   `terraform destroy` against flightdeck's own state files only. No tag-based
   or account-wide cleanup scripts, ever.
4. **Parent DNS zone (robertpuffe.com) is data-source-only** apart from the one
   NS delegation record for fd.robertpuffe.com. Existing records (apex, www,
   ACM validation CNAMEs) are untouchable.

## 6. The manifest contract (FINAL v1 — derived from the Stage 1 manual deploy)

```yaml
# app-manifest.yaml
name: my-app            # dns-safe, becomes service/log/target-group names + URL host
port: 8080
healthcheck: /healthz   # must return 200 within 30s of start
cpu: 256                # fargate units
memory: 512
env:                    # non-secret config only
  LOG_LEVEL: info
```

**Rule:** every field must be justified by a real need discovered during manual
deployment in W1. No speculative fields.

Outcomes of applying the rule: the draft's `secrets: []` field was never
needed and is gone (SSM injection lives in §11 v2); `image` is deliberately
NOT a manifest field — CI computes it per build, apps never pin their own
image reference.

**v0.4.0 addition — `storage: s3` (optional).** The first post-v1 field,
justified the same way: the arcade app spec (persistent high scores) needed
durable state. When set, the platform creates a private encrypted bucket per
environment, grants the task role access to exactly that bucket (its first
and only permission), and injects `STORAGE_BUCKET` (a reserved env key).
Absent = pre-v0.4.0 behavior, byte-identical. Healthchecks must never depend
on storage; data is destroyed with the stack.

## 7. The agent contract — structure (v0.2.0, restructured from one CONVENTIONS.md)

Redesigned after Stage 3 as a developer tool rather than a monolithic context
file — context is loaded per task, and rules are enforced by tooling at the
moment of failure instead of memorized upfront:

- `AGENTS.md` / `CLAUDE.md` (identical, ~20 lines) — the only always-loaded
  context: identity, "run `make preflight` before every push", untouchable
  files, and a doc index with "read the doc for the task at hand".
- `app-manifest.schema.json` — field rules (name regex, port range, valid
  Fargate cpu/memory pairs, string-only env) as machine-checkable schema.
- `make preflight` — mirrors CI's gates locally: manifest validation, amd64
  build, container boot + healthcheck within the 30s contract, the exact
  Trivy scans CI runs. Failures print the rule broken plus a pointer to the
  one doc that explains it. Turns multi-minute CI round-trips into local
  seconds.
- `docs/contract.md`, `docs/dockerfile.md`, `docs/pipeline.md`,
  `docs/example.md` — task-scoped depth, read on demand.
- The contract is handed to the coding agent alongside the app spec. Every
  agent failure in the loop patches the contract or the platform.

## 8. Work breakdown

### Stage 0 — Repo + bootstrap (Weekend 1, Saturday)
- [x] Create `flightdeck` repo (public)
- [x] `bootstrap/`: state backend, OIDC, ECR, VPC, DNS child zone + wildcard
      ACM cert, budget alarm
- [x] `make bootstrap` / `make destroy-bootstrap` work cleanly (destroy must
      respect §5b safeguards — parent zone survives untouched)
- [x] **Exit criteria:** clean account region → bootstrapped in one command

### Stage 1 — Manual golden path (Weekend 1, Sunday)
- [x] Write `modules/fargate-service`
- [x] Deploy a public sample container (e.g. nginxdemos/hello) via manual
      `terraform apply`
- [x] Write down every fact about the app you needed → that list becomes the
      final manifest schema
- [x] **Exit criteria:** sample container serving traffic at
      https://hello.fd.robertpuffe.com

### Stage 2 — CI + contract (Weekend 2, Saturday)
- [x] Reusable workflows: build-scan-push, terraform-plan-apply
- [x] tfsec/checkov + Trivy gates on
- [x] template-app repo with manifest + CONVENTIONS.md + thin CI caller
- [x] **Exit criteria:** push to a new app repo → deployed with zero pipeline config

### Stage 3 — The AI loop (Weekend 2, Sunday)
- [x] Write a small app spec (todo API or similar)
- [x] Hand spec + CONVENTIONS.md to Claude Code; agent writes the app
- [x] Log every failure; patch platform or conventions per failure
- [x] Repeat until spec → URL works end-to-end
- [x] **Exit criteria:** the 15-minute demo works; failure log has entries

### Stage 4 — Cross-agent test (half day, weekend 3)
- [ ] Same spec through Cursor and one other agent
- [ ] Pass/fail table in README
- [ ] **Exit criteria:** table exists; no platform changes unless a failure is
      a platform bug

### Stage 5 — Writeup (Weekend 3)
- [x] README: problem, architecture diagram, quickstart, failure log,
      "what I deliberately didn't build", day-2 future work
- [ ] **Exit criteria:** someone who's never met you understands and believes it

## 9. Success metrics

- Time-to-first-deploy for a new app: < 15 min including agent codegen
- Pipeline config required per app: 0 lines beyond the thin caller
- Monthly cost while idle: < $30 (destroy when not demoing)
- Agent failure log: > 5 documented failures with fixes (proof of hardening)
- Reader test: someone new to the project gets the point in < 5 min from the
  README alone, without cloning anything (§3a; restated as Stage 5 exit)

## 10. Risks / open decisions

**Decided (2026-07-10):** NAT = fck-nat (cost-conscious, documented tradeoff).
ECR began repo-per-app via `for_each`; the next hardening release splits dev
and prod repositories per app so dev retention can never delete a deployed
production image. The original repository name remains prod for migration
continuity.
Name = flightdeck.

**Decided (2026-07-10, review pass):**
- Deploy model = pinned imports + boilerplate main.tf (§5a). Resolves the
  "Terraform state in CI" open question: per-app keys in the shared bucket.
- TLS/DNS = child zone fd.robertpuffe.com + wildcard ACM; apps get
  `https://<name>.fd.robertpuffe.com`. Host-based ALB routing on one shared ALB.
- Region = us-east-1. Account = existing personal (safeguards in §5b).
- Scan gates fail on HIGH/CRITICAL only, documented as a deliberate threshold.
  Scanner = Trivy for BOTH image and IaC (decided W2: tfsec merged into Trivy
  upstream, and open-source checkov cannot filter by severity, which the
  HIGH/CRITICAL-only gate requires — one scanner, working thresholds).

**Decided (2026-07-10, v0.3.0 — §11's multi-env item graduated; the v1
writeup gate was satisfied):**
- Environments: push to main → dev (`<name>-dev.fd...`, rides the existing
  wildcard cert); tag v* → prod (`<name>.fd...`). Promotion deploys the SAME
  immutable image main built by copying its OCI manifest from the dev ECR
  repository to prod and verifying the digest — build once, promote the
  artifact, never rebuild.
- PR checks run with ZERO cloud credentials (build + both Trivy gates +
  fmt/validate). OIDC trust covers main + v* tag refs only — unmerged code
  never holds credentials. Plan-preview-on-PR needs a separate read-only
  plan role → §11.
- Prod state stays at the legacy key (`apps/<name>/terraform.tfstate`), dev
  at `apps/<name>/dev/` — existing apps get prod continuity with zero state
  migration. Module `environment=prod` is byte-identical to pre-v0.3.0
  naming, so adopting the tag is an empty prod diff.
- App name limit tightened 20 → 16 chars (the `-dev` suffix must fit AWS's
  32-char target-group name limit).
- No per-env manifest overrides in v0.3.0 — nothing has needed one yet
  (§6 rule applies to env features too).

**Decided (2026-07-11, v0.4.0 — first stateful feature):**
- `storage: s3` manifest field per §6's v0.4.0 note. S3 before RDS on
  purpose: no networking, no credentials, no schema — the cheapest durable
  state that proves the pattern (conditional resources + scoped task-role
  grant + injected env). The RDS `database:` block (§11) inherits this shape
  when something needs it.
- Deploy role gets `s3:*` resource-scoped to `flightdeck-*-data-*` — the
  pattern cannot match the tfstate bucket; enumerating thirty bucket
  sub-resource actions adds noise, not safety.

**Decided (2026-07-11, v0.5.0 — app lifecycle, graduating §4's "upgrades"
by owner decision):**
- `make new-app NAME=x` (platform repo): scaffold + manifest name + git init
  + registry append. Deliberately does NOT run gh repo create or terraform
  apply — externally-visible actions stay explicit.
- `make upgrade [TAG=x]` (app repos): fetches the release tarball and
  replaces every platform-owned file; the template at a tag pins that tag,
  so refs bump as a side effect of file replacement — one operation, no
  skew. Refuses on ANY uncommitted state (tracked or untracked) under
  replaced paths, with commit-or-stash wording. Warns on manifest fields the
  target schema doesn't know (downgrade safety). Never commits.
- `.flightdeck-version` records the contract version; preflight warns (not
  fails) when it disagrees with main.tf's pinned ref.
- App test commands move from the Makefile to an app-owned `test.sh` —
  every platform-shipped file becomes whole-file replaceable.
- One-time bootstrap for pre-v0.5.0 apps (no upgrade target yet): curl the
  tagged Makefile, then `make upgrade` — documented in docs/pipeline.md.
- Design was subagent-reviewed before build (GO WITH CHANGES; all six
  findings incorporated, including a verified tag-discovery bug).

**Decided (2026-07-12 — fleet cooling, second day-2 graduation by owner
decision):**
- One reusable scaler Lambda, two front doors: EventBridge Scheduler cron
  (nightly stop-all, 23:30 America/Chicago) and an ALB wake endpoint at
  wake.fd.robertpuffe.com riding the existing wildcard cert/alias — no API
  Gateway, no new edge infrastructure.
- The HTTP path is START-ONLY by construction: an open wake endpoint can at
  worst keep services warm (bounded by the budget alarm), never cause an
  outage. Stopping happens only via schedule, make targets, or direct
  invoke.
- Same drift semantics as the service-ops targets: terraform owns
  desired_count=1; any deploy re-warms its service; the nightly cron
  re-cools. "wake" becomes a reserved hostname.
- Full scale-from-zero (auto-wake when a sleeping app's own URL is hit,
  via listener-rule flipping) remains open on the tracker — the wake
  endpoint is the deliberate 80% version.
- Tracking = GitHub Issues + one Milestone per Stage on rpuffe/flightdeck.
- Stage 3 demo app = agent's choice of language (the language-agnosticism IS
  the thesis).
- The 15-minute claim starts AFTER `make bootstrap`; README must say so.

| Risk | Mitigation |
|---|---|
| Scope creep (CLI, portal, k8s) | Non-goals section is binding; new ideas go to §11 roadmap |
| Terraform state in CI for app repos | Decide W2: per-app state keys in the shared bucket |
| Secrets handling complexity | v1: env vars only; SSM injection is a stretch goal |
| Spec-polishing instead of building | This doc is frozen after one review pass. Edits only from build learnings. |

## 11. Roadmap — v2 and beyond (parking lot)

Ideas land here instead of in v1 scope. Nothing below starts until the v1
writeup exists. Roughly ordered by value-per-effort, not chronology.

### v2 — platform depth (makes the demo more real)
- **Secrets injection via SSM Parameter Store** — populate the `secrets:` manifest
  field; task role gets least-privilege read on its own path only.
- **Multi-environment promotion** — SHIPPED in v0.3.0 (see §10): dev on main,
  prod on tag, build-once artifact promotion. Env-specific manifest overrides
  remain future work (none needed yet).
- **Plan preview on PRs via a read-only plan role** — PR checks are
  deliberately credential-free; a separate role with read-only + state-read
  permissions would enable `terraform plan` comments on PRs without handing
  write credentials to unmerged code.
- **Preview environments per PR** — ephemeral stack per pull request, auto-destroyed
  on merge/close. Very demoable; watch cost.
- **Second service type: worker/cron** — manifest grows a `type:` field
  (web | worker | scheduled). Proves the contract generalizes.
- **RDS/Aurora module** — optional `database:` block in the manifest. Brings the
  platform closer to real app shapes; state and teardown get harder, so v2 not v1.

### v3 — developer/agent experience
- **Thin CLI** — Python/Click wrapper over the Makefile targets, agent-generated in
  an afternoon. Explicitly deferred because standard tools are more agent-friendly;
  build only if a human-DX story needs it.
- **Cross-agent compatibility matrix as a living benchmark** — rerun the Stage 4
  spec against new agent releases quarterly; keep the table current.
- **Escape hatch design** — sanctioned deviation mechanism (e.g. raw task-def
  override block). v1 deliberately has none; designing one well is a substantial
  design writeup on its own.

### v4 — operate it like a product (day-2)
- **Observability beyond alarms** — dashboards per service, structured log queries,
  maybe traces. The day-2 story v1 explicitly skips.
- **Drift detection** — scheduled `terraform plan` in CI, alert on drift.
- **Per-app cost visibility** — tag-based cost allocation surfaced in the README or
  a tiny report. Pairs with the HIPAA/governance narrative.
- **Deploy strategies** — blue/green or canary via CodeDeploy on ECS.
- **Service catalog / portal** — only if the platform grows real users; evaluate
  Backstage integration vs. staying deliberately minimal. Write the comparison
  either way — "why I still haven't built a portal" is a legitimate position piece.

### Explicitly rejected (revisit only with new information)
- Kubernetes/EKS port — different audience, doubles surface area.
- OpenTofu switch — no current differentiator (TF ≥1.10 has native S3 locking);
  fine as a footnote, not worth a migration.
- Rebuilding a Copilot-style full CLI — the CLI was Copilot's liability, not its value.
