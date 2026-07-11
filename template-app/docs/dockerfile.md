# Dockerfile rules

Read this when writing or editing the Dockerfile.

- **Base image: current and slim** — `*-alpine`, `*-slim`, or distroless.
- **Upgrade OS packages in the Dockerfile**: `apk upgrade --no-cache` (or
  `apt-get upgrade -y`). Not optional — even current official images lag CVE
  fixes by days, and the image scan gate fails on fixable HIGH/CRITICAL
  findings before your code ever runs. (This caught a real CVE in a current
  official `nginx-unprivileged` image — see `docs/pipeline.md`.)
- **Strip package managers the container never invokes at runtime** — npm,
  pip, etc. Their bundled dependencies carry CVEs of their own, independent
  of your app's dependencies: `node:22-alpine`'s bundled npm has failed the
  image scan gate on an app with zero npm dependencies. Once your build
  stage is done, remove them (`rm -rf` the npm/npx/corepack binaries or
  equivalent) so the runtime image doesn't carry them.
- **Declare a non-root `USER` explicitly**, even if the base image already
  runs as one. Trivy's Dockerfile check (DS002, HIGH) inspects the
  Dockerfile itself, not the base image's runtime user — it can't see that
  e.g. `nginx-unprivileged` already switches users, so declare `USER`
  anyway.
- **`EXPOSE` must match the manifest's `port`** exactly.
- **Scan locally before pushing**: `trivy image --severity HIGH,CRITICAL
  <tag>` — the same gate CI runs, and the same one `make preflight` runs.
  Catch it here, not in a failed pipeline run.
