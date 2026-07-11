# Runtime contract

Read this when writing or reviewing application code or the Dockerfile's
runtime behavior (not its build rules — see `docs/dockerfile.md` for those).

## What the platform provides — do not build or code around any of it

- **Public HTTPS URL**: `https://<name>.fd.robertpuffe.com`, TLS terminated
  at the load balancer. `<name>` comes from `app-manifest.yaml`.
- **Logs**: everything written to stdout/stderr lands in CloudWatch Logs
  automatically.
- **Restart and rollback**: crashed containers are restarted; a deploy whose
  containers fail their health check is rolled back automatically.
- **Health monitoring and alarms**: the platform polls your healthcheck path
  and alarms on sustained CPU or health-check failures.

The app never touches AWS, Terraform, or DNS. No AWS SDK infra calls, no
`.tf` files, no domain/certificate config. If the spec seems to need any of
that, the platform already provides it, or v1 doesn't support it.

## What your app must do

1. **Build a `linux/amd64` image.** Don't assume the build host's
   architecture; any `--platform` you set must be `linux/amd64`.
2. **Bind `0.0.0.0` on the manifest's `port`.** If your framework defaults
   to a different port, configure it — the two values must agree exactly.
3. **Answer the healthcheck with 200 within 30s of container start.** Keep
   it dependency-free (no DB/network calls) so a slow dependency can't fail
   the deploy.
4. **Log to stdout/stderr only.** No log files, no shippers, no agents —
   anything written to disk is invisible and lost.
5. **Be stateless.** The container filesystem can vanish on any deploy,
   restart, or scaling event. v1 has no database or volume support; if the
   spec needs persistence, in-memory state is the v1 answer and data loss
   on restart is accepted.
6. **Run non-root, on an unprivileged port.** No root at runtime, no port
   below 1024, no Docker socket, kernel parameters, or host devices. Add a
   non-root `USER` to the Dockerfile (details in `docs/dockerfile.md`).
7. **Take all config from env vars** in the manifest's `env:` map. No
   per-environment config files, no machine-specific flags. Use sane
   defaults so the app also runs locally without the manifest.
8. **No secrets, anywhere — hard constraint, not an inconvenience.** No API
   keys, tokens, passwords, or credentials in `env:`, in code, in the
   Dockerfile, or in the repo. v1 has no secret support. If the spec
   requires a secret, **stop and flag it**: the app cannot be built on v1
   as specced.
