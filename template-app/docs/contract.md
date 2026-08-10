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
that, the platform already provides it, or v1 doesn't support it. **There are
exactly two sanctioned exceptions**: if the manifest sets `storage: s3`, S3
SDK calls against your injected `STORAGE_BUCKET` are allowed (see Storage
below); if it sets `email:`, SES send calls as your injected `MAIL_FROM` are
allowed (see Email below). That is the entire list — no other AWS SDK calls,
no calls to any bucket other than the injected one, and no sending as any
address other than the injected one. (`auth: cognito` adds no exception —
sign-in uses plain OIDC over HTTPS, no AWS SDK involved; see Auth below.)

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
7. **Take all config from env vars.** Put non-secret values in the manifest's
   `env:` map and declare secret names under `secrets:`. No per-environment
   config files or machine-specific flags. Use sane defaults so the app also
   runs locally without the manifest.
8. **Secret values never belong in source-controlled inputs.** No API keys,
   tokens, passwords, or credentials in `env:`, code, Dockerfiles, manifests,
   Terraform variables, or the repo. Declare names only under `secrets:` and
   use the operator workflow below to store values out of band.

## Managed secrets (optional)

```yaml
secrets:
  - SIGNWELL_API_KEY
```

- Names must match `^[A-Z][A-Z0-9_]{0,63}$`, be unique, and cannot overlap
  `env:` or platform-reserved keys. At most 20 are allowed.
- Dev and prod are separate SSM Standard `SecureString` parameters at
  `/flightdeck/<app>/<environment>/<NAME>`. Terraform state and ECS task
  definitions contain parameter ARNs, never values.
- From a Flightdeck checkout, use `make secret-set`, `secret-check`, or
  `secret-rotate` with `MANIFEST`, `ENV`, and `NAME`. `secret-set` is
  creation-only; an existing parameter must use `secret-rotate`, which forces
  a new ECS deployment because secrets are injected only at task start. Values
  are prompted silently and never accepted on the command line.
- To remove a credential: revoke it at the provider first, remove the manifest
  declaration and deploy, then run the confirmation-gated `secret-delete`.
- ECS reads parameters through the task **execution role**, scoped to the app
  and environment path. The application task role gets no SSM API access.
- Local preflight intentionally injects no secrets. The app must boot and its
  healthcheck must pass with integrations disabled when a secret is absent
  locally. A deployed manifest whose parameter is missing or unreadable fails
  task startup visibly.
- Never print a secret or include it in an exception, response, or log.

## Storage (optional)

Set `storage: s3` in `app-manifest.yaml` if the spec needs data to survive a
restart or redeploy, or `storage: s3-retained` if the data must also survive
a full stack teardown (production data, not demo data). Nothing else to
configure — no bucket name, no ARN, no IAM policy. Both values behave
identically at runtime; they differ only in durability posture (last two
bullets below).

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
- **`s3`: data is destroyed with the stack.** The bucket is `force_destroy`
  — built for a teardown-first platform. Tearing down this app's stack
  deletes the bucket and everything in it, permanently. Don't treat this as
  durable backup storage across a full teardown/rebuild cycle.
- **`s3-retained`: data survives the stack.** The bucket is versioned
  (noncurrent versions kept 90 days) and `force_destroy` is off, so a stack
  teardown **fails on the bucket by design** while it holds any data — that
  failure is the break-glass, not a bug. Deleting retained production data
  requires an operator to deliberately empty the bucket (all versions;
  CI's deploy role cannot purge version history), or downgrading the
  manifest to `storage: s3`, applying, and then destroying. Upgrading
  `s3` → `s3-retained` is an in-place change to the same bucket — no data
  migration.
- **Deploys are stop-then-start.** Opting into `storage:` changes deploy
  semantics: the platform stops and drains the old task before starting its
  replacement, so at most one task ever runs. This guarantees a local
  database replicating to the bucket never has two concurrent writers, at
  the cost of roughly a minute of unavailability per deploy. Stateless apps
  (no `storage:`) keep zero-downtime rolling deploys.

## Alerts (optional)

Add an `alerts:` list to `app-manifest.yaml` if some log lines signal a
failure worth notifying a human about — the classic case is a replication
or sync process that can fail while the healthcheck stays green:

```yaml
alerts:
  - name: replication-error
    pattern: '"level=ERROR"'
```

- **What happens**: everything your container prints already lands in a
  CloudWatch log group. Each entry adds a metric filter on that log group
  and an alarm: any matching line within a 5-minute window triggers a
  notification to the platform's alert email.
- **`name`**: DNS-safe (lowercase/digits/hyphens, starts with a letter,
  max 32 chars), unique within the list; becomes the alarm-name suffix.
- **`pattern`**: [CloudWatch Logs filter
  syntax](https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/FilterAndPatternSyntax.html),
  passed through verbatim. Quote terms (`'"level=ERROR"'`) to match them
  literally. Test against real log output — an unmatched pattern alarms
  never, an over-broad one alarms constantly.
- **Limits**: at most 10 entries. Alerts are for actionable failures, not
  log analytics — if you need more, the signal is probably too noisy.
- Absent = no new resources, exactly the pre-v0.7.0 behavior.

## Auth (optional)

Set `auth: cognito` in `app-manifest.yaml` if the spec needs users to sign
in. Nothing else to configure — no user pool, no OAuth app registration, no
client secret, no IAM.

- **What arrives**: four env vars, all reserved keys (`make preflight`
  rejects a manifest that also defines them in `env:`):
  - `COGNITO_USER_POOL_ID` — the pool id.
  - `COGNITO_CLIENT_ID` — the app client id.
  - `COGNITO_DOMAIN` — the hosted-login hostname (no scheme).
  - `COGNITO_ISSUER` — the OIDC issuer URL; token verification and
    discovery (`$COGNITO_ISSUER/.well-known/openid-configuration`) hang
    off it.
- **How to use it**: standard OIDC authorization-code flow **with PKCE**
  against the hosted UI at `https://$COGNITO_DOMAIN`. The client is public —
  there is no client secret; if a library insists on one, configure it as a
  public client. Redirect URI must be exactly
  `https://<your-url>/auth/callback` — that path is registered by the
  platform, so implement your callback handler there. Verify JWTs against
  `$COGNITO_ISSUER/.well-known/jwks.json` (check issuer, audience =
  `COGNITO_CLIENT_ID`, expiry).
- **No AWS involved**: sign-in, token exchange, and verification are plain
  HTTPS to Cognito's public endpoints — no AWS SDK calls, no credentials.
  The task role stays permissionless; Cognito admin APIs (server-side user
  creation etc.) are not supported in this version — if the spec needs
  them, stop and flag it.
- **Per-environment isolation**: dev and prod each get their own pool. User
  accounts never cross. The dev client additionally allows
  `http://localhost:<port>/auth/callback` for local testing against the
  dev pool; the prod client accepts only the real URL.
- **Graceful degradation is part of the contract, not optional.** With no
  `auth:` set, or when running locally (`make preflight` / `make run`), the
  `COGNITO_*` vars are unset — your app **must still boot and pass its
  healthcheck**. The healthcheck path must never require login; when the
  vars are absent, run with sign-in disabled rather than crashing.
- **User accounts are destroyed with the stack.** The pool has deletion
  protection off — teardown-first platform. Tearing down this app's stack
  deletes the pool and every user in it, permanently.

## Email (optional)

```yaml
email:
  from: billing@example.com
```

Set this if the spec needs your app to send mail. The task role gains
permission to send through SES as exactly that address and nothing else.

- **What arrives**: two reserved env vars (`make preflight` rejects a
  manifest that also defines them in `env:`):
  - `MAIL_FROM` — the address to send as. **Use this value verbatim as the
    envelope From**; a different address is denied by IAM. A display name is
    fine when you compose the message (`Studio <$MAIL_FROM>`), but the
    address inside it must match.
  - `MAIL_REGION` — the region to construct the SES client with. Fargate does
    not set `AWS_REGION`, so a client built without this has no region to
    resolve.
- **How to call it**: the AWS SDK's default credential chain, same as
  storage — no keys to manage. `ses:SendEmail` and `ses:SendRawEmail` only;
  no identity management, no template, no configuration-set APIs.
- **Dev never sends as the production address.** In dev, `MAIL_FROM` is
  forced to `<name>-dev@fd.robertpuffe.com` no matter what the manifest
  declares. Bounces and test loops spend sending reputation, and SES
  reputation is account-wide — dev traffic must never spend production's.
  Read the address from the env var and this costs you nothing.
- **Two prerequisites the manifest cannot express**, both operator-side:
  1. The From domain must be a **verified SES identity**. The platform zone
     (`fd.robertpuffe.com`) is Terraform-managed, so dev works as soon as
     the feature is on. A production domain whose Route53 zone is in the
     same account can be Terraform-managed too — the operator lists it in
     `mail_managed_zones` and its identity, DKIM, SPF, and DMARC records are
     created for it. A domain hosted anywhere else is verified through the
     SES console, with its DKIM records added at that domain's registrar.
  2. The app must be listed in the platform's **`mail_senders` registry**
     with this exact address. An app cannot grant itself sending by editing
     its own manifest — declaring `email:` without the operator-side grant
     deploys fine and then fails at send time with `AccessDenied`.
- **The SES sandbox is on until you leave it.** A new account can only send
  to verified addresses. Reaching real recipients needs a one-time
  production-access request to AWS support, per account.
- **Graceful degradation is part of the contract, not optional.** With no
  `email:` set, or when running locally (`make preflight` / `make run`),
  `MAIL_FROM` is unset — your app **must still boot and pass its
  healthcheck**. Treat mail as disabled when the var is absent (queue it,
  log it, or show it as unsent) rather than crashing at startup.
- **Prefer failing loudly over silently.** A send that is denied or
  throttled must surface — an `alerts:` entry on your error signature is the
  intended mechanism, since a green healthcheck hides undelivered mail.

**The alternative, if you'd rather not take the IAM grant**: SES also speaks
SMTP with static credentials, which are just two entries under `secrets:` and
need no platform support at all. That trades this scoped, rotation-free grant
for a long-lived credential you own and rotate. Either is supported; `email:`
is the one the platform manages.
