# Runtime contract

Read this when writing or reviewing application code or the Dockerfile's
runtime behavior (not its build rules — see `docs/dockerfile.md` for those).

## What the platform provides — do not build or code around any of it

- **Public HTTPS URL**: push to `main` deploys dev at
  `https://<name>-dev.fd.robertpuffe.com`; tagging `v*` promotes the same
  image to prod at `https://<name>.fd.robertpuffe.com`. TLS terminated at
  the load balancer. `<name>` comes from `app-manifest.yaml` — max 16
  characters (the `-dev` suffix has to fit AWS's 32-char target-group name
  limit). See `docs/pipeline.md` for the full trigger/environment model.
- **Logs**: everything written to stdout/stderr lands in CloudWatch Logs
  automatically.
- **Restart and rollback**: crashed containers are restarted; a deploy whose
  containers fail their health check is rolled back automatically.
- **Health monitoring and alarms**: the platform polls your healthcheck path
  and alarms on sustained CPU or health-check failures.

The app never touches AWS, Terraform, or DNS. No AWS SDK infra calls, no
`.tf` files, no domain/certificate config. If the spec seems to need any of
that, the platform already provides it, or v1 doesn't support it. **The one
sanctioned exception**: if the manifest sets `storage: s3`, S3 SDK calls
against your injected `STORAGE_BUCKET` are allowed — see Storage below. That
is the entire exception; no other AWS SDK calls, and no calls to any bucket
other than the injected one.

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
5. **No local persistence.** The container filesystem can vanish on any
   deploy, restart, or scaling event — never write state there. Durable
   state exists only through the optional `storage: s3` opt-in (see below);
   without it, in-memory state is the v1 answer and data loss on restart is
   accepted.
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

## Storage (optional)

Set `storage: s3` in `app-manifest.yaml` if the spec needs data to survive a
restart or redeploy. Nothing else to configure — no bucket name, no ARN, no
IAM policy.

- **What arrives**: a `STORAGE_BUCKET` env var with the bucket name.
  `STORAGE_BUCKET` is a reserved key — `make preflight` rejects a manifest
  that also defines it in `env:`.
- **How to call it**: use the AWS SDK's default credential chain (no keys to
  manage, nothing to configure). This is the one sanctioned exception to
  "never touch AWS" above.
- **Permission boundary**: the app's task role can read/write exactly this
  one bucket and nothing else in the account — it's otherwise permissionless.
  Don't assume access to any other bucket or AWS resource.
- **Per-environment isolation**: dev and prod each get their own bucket. The
  dev bucket and the prod bucket never share data.
- **Graceful degradation is part of the contract, not optional.** With no
  `storage:` set, or when running locally (`make preflight` / `make run`),
  there is no AWS and `STORAGE_BUCKET` is unset — your app **must still boot
  and pass its healthcheck**. Never let the healthcheck (or startup) depend
  on S3 being reachable; fall back to in-memory state when the bucket isn't
  there.
- **Data is destroyed with the stack.** The bucket is `force_destroy` —
  built for a teardown-first platform. Tearing down this app's stack deletes
  the bucket and everything in it, permanently. Don't treat this as durable
  backup storage across a full teardown/rebuild cycle.
