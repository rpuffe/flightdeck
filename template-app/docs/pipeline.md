# Pipeline

Read this when a PR check, a push to `main`, or a `v*` tag fails — or before
pushing/tagging if you want to know what's about to run.

## Three triggers, three jobs

- **Pull request** runs PR checks: docker build → **Trivy image scan gate**
  → **Trivy IaC scan gate** → `terraform fmt`/`validate`. **Zero cloud
  credentials** — OIDC trust covers only `refs/heads/main` and
  `refs/tags/v*`, deliberately excluding PR refs, so unmerged code never
  holds credentials. That's why there's no `terraform plan` preview on PRs:
  plan needs a role to assume, and PRs don't get one, on purpose.
- **Push to `main`** builds, scans, pushes to ECR, then `terraform
  plan`/`apply`s to **dev**: `https://<name>-dev.fd.robertpuffe.com`.
- **Tag `v*`** promotes to **prod**: `https://<name>.fd.robertpuffe.com`.
  Promotion does not rebuild or re-scan — it looks up the image already
  pushed to ECR for the tagged commit's SHA and applies that exact image.
  Dev and prod always run the bit-identical artifact; only the Terraform
  state and target environment differ.

Both scan gates fail on HIGH/CRITICAL findings only — a deliberate,
documented threshold, not every low-severity finding.

## Promotion only works on a commit that reached `main`

A tag promotes an image, not source — there is nothing to build at tag
time. So the commit you tag must already have gone through a `main` push
(which is what puts its image in ECR). Tag a commit that was never pushed
to `main` — a branch tip, a squashed/rebased commit with a different SHA,
anything main hasn't built — and promotion fails fast with:

```
no image for commit <sha> — promotion deploys the image main already
built and validated in dev; tag a commit that has been pushed to main
```

Fix: push the commit to `main` first (let dev build and deploy it), then
tag that same SHA.

## Failure → fix playbook

- **Image gate fails** (on a PR or on `main`): almost always stale OS
  packages in the base image, or CVEs bundled inside a package manager the
  app doesn't use at runtime. Fix per `docs/dockerfile.md`: `apk
  upgrade`/`apt-get upgrade`, and strip unused package managers. Confirm
  locally with `trivy image --severity HIGH,CRITICAL <tag>` before
  repushing.
- **IaC gate fails inside the platform's own `fargate-service` module**:
  expected, not your bug. The scan follows Terraform module sources, so it
  reaches into the platform module by design; any accepted findings there
  are already reviewed and documented inline in the module. Nothing to fix
  in your app repo.
- **`terraform apply` fails** (dev on push, prod on tag): read the actual
  error with `gh run view --log-failed` (it shows only the failing step's
  log). Most causes are manifest values the schema should already have
  caught — if `make preflight` passed but apply still fails for a
  schema-shaped reason, that's a platform bug, not something to work
  around.
- **Promotion fails with "no image for commit"**: the tag points at a
  commit `main` never built. See the promotion rule above — push to `main`
  first, then tag that SHA.
- **Health checks flap right after apply**: normal, in either environment.
  Give newly deployed tasks about **2 minutes** to stabilize and pass their
  target-group health check before the platform reports steady state.
  Don't panic-redeploy inside that window.
