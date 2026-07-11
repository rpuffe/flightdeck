<!-- Kept identical to AGENTS.md: Claude Code auto-loads CLAUDE.md, other tools read AGENTS.md. -->

# flightdeck app contract

A flightdeck app is a Dockerfile + `app-manifest.yaml`: the platform builds,
scans, deploys, and serves it as an HTTPS service. You never touch AWS,
Terraform, or DNS.

**Run `make preflight` before every push** — it mirrors CI's gates locally
(manifest validation, image build, container boot + healthcheck, Trivy scans).

**Never edit `main.tf` or `.github/workflows/ci.yml`.** Both are pinned
platform boilerplate; editing either takes the app off the platform.

**The manifest is `app-manifest.yaml`**, validated against
`app-manifest.schema.json` — let `make preflight` catch field-level mistakes.

## Docs — read the one for the task at hand, not all of them upfront

- `docs/contract.md` — runtime expectations: what your app must do, what the platform already does for you.
- `docs/dockerfile.md` — image rules and scan gates.
- `docs/pipeline.md` — what a push to `main` triggers, and a failure→fix playbook.
- `docs/example.md` — a worked example, built end-to-end.
