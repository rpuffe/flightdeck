# Flightdeck — Spec-to-Production Golden Path for AI-Generated Apps

**Name:** flightdeck (rename is cheap if needed later — decided, don't revisit)
**Owner:** Robert
**Status:** Draft v1
**Timebox:** Demo-able v1 in 2 weekends. Writeup by end of weekend 3.

---

## 1. One-liner

A minimal golden path on AWS — Terraform modules, reusable GitHub Actions, and a
manifest contract — so that an AI coding agent can take a plain-language spec to a
production-grade deployment with guardrails, in minutes, without touching
infrastructure.

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
4. A conventions doc (`CONVENTIONS.md`) that a coding agent consumes as context.
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
- No day-2 operations (upgrades, dashboards beyond basic alarms). Named future work.

## 5. Architecture

Two Terraform layers, mirroring the account/service split (lesson from operating
AWS Copilot in production):

```
repo: flightdeck (github.com/rpuffe/flightdeck, public)
├── bootstrap/            # account-level, applied once
│   ├── state backend (S3, native lockfile — TF >= 1.10)
│   ├── GitHub OIDC provider + deploy role
│   ├── ECR repo-per-app via for_each
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
│   ├── build-scan-push.yml   (docker build, Trivy scan, push to ECR)
│   ├── terraform-plan-apply.yml  (fmt, validate, tfsec/checkov, plan, apply)
│   └── deploy.yml            (calls the above; triggered on merge to main)
├── template-app/         # GitHub template repo contents
│   ├── app-manifest.yaml
│   ├── CONVENTIONS.md    # the agent-facing context file
│   ├── Dockerfile        # placeholder, agent replaces
│   └── .github/workflows/ci.yml  # thin caller of reusable workflows
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

## 6. The manifest contract (draft — finalize from what W1 actually requires)

```yaml
# app-manifest.yaml
name: my-app            # dns-safe, becomes service/repo/log names
port: 8080
healthcheck: /healthz   # must return 200 within 30s of start
cpu: 256                # fargate units
memory: 512
env:                    # non-secret config only
  LOG_LEVEL: info
secrets: []             # SSM parameter names, injected at runtime (stretch)
```

**Rule:** every field must be justified by a real need discovered during manual
deployment in W1. No speculative fields.

## 7. CONVENTIONS.md (agent contract) — contents

- What the platform provides (URL, TLS, logs, restart on failure) and expects
  (Dockerfile, manifest, health endpoint, listen on `$PORT`, log to stdout).
- Explicit constraints: no local disk persistence, no privileged containers,
  stateless, 12-factor config via env.
- One worked example.
- This file is handed to the coding agent alongside the app spec. Every agent
  failure in Stage 2 patches either this doc or the platform.

## 8. Work breakdown

### Stage 0 — Repo + bootstrap (Weekend 1, Saturday)
- [ ] Create `flightdeck` repo (public)
- [ ] `bootstrap/`: state backend, OIDC, ECR, VPC, DNS child zone + wildcard
      ACM cert, budget alarm
- [ ] `make bootstrap` / `make destroy-bootstrap` work cleanly (destroy must
      respect §5b safeguards — parent zone survives untouched)
- [ ] **Exit criteria:** clean account region → bootstrapped in one command

### Stage 1 — Manual golden path (Weekend 1, Sunday)
- [ ] Write `modules/fargate-service`
- [ ] Deploy a public sample container (e.g. nginxdemos/hello) via manual
      `terraform apply`
- [ ] Write down every fact about the app you needed → that list becomes the
      final manifest schema
- [ ] **Exit criteria:** sample container serving traffic at
      https://hello.fd.robertpuffe.com

### Stage 2 — CI + contract (Weekend 2, Saturday)
- [ ] Reusable workflows: build-scan-push, terraform-plan-apply
- [ ] tfsec/checkov + Trivy gates on
- [ ] template-app repo with manifest + CONVENTIONS.md + thin CI caller
- [ ] **Exit criteria:** push to a new app repo → deployed with zero pipeline config

### Stage 3 — The AI loop (Weekend 2, Sunday)
- [ ] Write a small app spec (todo API or similar)
- [ ] Hand spec + CONVENTIONS.md to Claude Code; agent writes the app
- [ ] Log every failure; patch platform or conventions per failure
- [ ] Repeat until spec → URL works end-to-end
- [ ] **Exit criteria:** the 15-minute demo works; failure log has entries

### Stage 4 — Cross-agent test (half day, weekend 3)
- [ ] Same spec through Cursor and one other agent
- [ ] Pass/fail table in README
- [ ] **Exit criteria:** table exists; no platform changes unless a failure is
      a platform bug

### Stage 5 — Writeup (Weekend 3)
- [ ] README: problem, architecture diagram, quickstart, failure log,
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
ECR = repo-per-app via `for_each` (cleaner lifecycle rules and scoped permissions).
Name = flightdeck.

**Decided (2026-07-10, review pass):**
- Deploy model = pinned imports + boilerplate main.tf (§5a). Resolves the
  "Terraform state in CI" open question: per-app keys in the shared bucket.
- TLS/DNS = child zone fd.robertpuffe.com + wildcard ACM; apps get
  `https://<name>.fd.robertpuffe.com`. Host-based ALB routing on one shared ALB.
- Region = us-east-1. Account = existing personal (safeguards in §5b).
- Scan gates fail on HIGH/CRITICAL only (Trivy and checkov), documented as a
  deliberate threshold.
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
- **Multi-environment promotion** — dev → prod with the same manifest, env-specific
  overrides, promotion on tag. This is the single biggest realism upgrade.
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
