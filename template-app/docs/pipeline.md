# Pipeline

Read this when a push to `main` fails, or before pushing if you want to know
what's about to run.

Every push to `main` runs, in order: build image → **Trivy image scan
gate** → push to ECR → **Trivy IaC scan gate** → `terraform plan` →
`terraform apply`. Both scan gates fail on HIGH/CRITICAL findings only — a
deliberate, documented threshold, not every low-severity finding.

## Failure → fix playbook

- **Image gate fails**: almost always stale OS packages in the base image,
  or CVEs bundled inside a package manager the app doesn't use at runtime.
  Fix per `docs/dockerfile.md`: `apk upgrade`/`apt-get upgrade`, and strip
  unused package managers. Confirm locally with `trivy image --severity
  HIGH,CRITICAL <tag>` before repushing.
- **IaC gate fails inside the platform's own `fargate-service` module**:
  expected, not your bug. The scan follows Terraform module sources, so it
  reaches into the platform module by design; any accepted findings there
  are already reviewed and documented inline in the module. Nothing to fix
  in your app repo.
- **`terraform apply` fails**: read the actual error with `gh run view
  --log-failed` (it shows only the failing step's log). Most causes are
  manifest values the schema should already have caught — if `make
  preflight` passed but apply still fails for a schema-shaped reason,
  that's a platform bug, not something to work around.
- **Health checks flap right after apply**: normal. Give newly deployed
  tasks about **2 minutes** to stabilize and pass their target-group health
  check before the platform reports steady state. Don't panic-redeploy
  inside that window.
