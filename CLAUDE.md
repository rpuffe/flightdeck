# flightdeck

Golden path platform: plain-language spec → production-grade AWS deployment
via Terraform, reusable GitHub Actions, and an `app-manifest.yaml` contract.
`spec-docs/flightdeck-spec.md` is the source of truth — read §4 (non-goals),
§5a (deploy model), and §5b (safeguards) before changing anything.

## Commands

- `make fmt` / `make validate` — format and validate bootstrap Terraform
- `make plan-bootstrap` — plan (read-only AWS calls)
- `make bootstrap` / `make destroy-bootstrap` — apply/destroy account-level stack
- `make ps` — list every service with desired/running counts and URL
- `make stop SVC=<name>` / `make start SVC=<name>` — scale one service 0/1
- `make stop-all` / `make start-all` — the overnight off-switch (deliberate
  drift: any service's next deploy restores desired=1)

## Binding conventions

- Spec §5b safeguards are absolute: net-new resources only, never import or
  modify pre-existing ones; the parent DNS zone is data-source-only apart from
  the single NS delegation record.
- Every resource: `flightdeck-` name prefix; `project=flightdeck` tags come
  from provider default_tags — don't re-tag per resource.
- Manifest fields must be justified by a real need found during manual
  deployment (spec §6). No speculative fields.
- Scan gates (Trivy, checkov) fail on HIGH/CRITICAL only — deliberate,
  documented threshold.
- Scope discipline: new ideas go to spec §11 (roadmap parking lot), not into
  v1. The non-goals section (§4) is binding.

## Subagent Usage

- Use subagents whenever possible 
- Always choose the lowest cost agent that is still capable of doing the task.

