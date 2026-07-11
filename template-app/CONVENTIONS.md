# Flightdeck conventions — the app contract

You are writing an application that deploys on flightdeck, a golden-path
platform on AWS. This document plus the app spec you were given is everything
you need. Follow it exactly: the platform has no escape hatches, so anything
outside this contract does not deploy.

## What the platform provides

You get all of this for free. Do not build, configure, or code around any of it.

- **A public HTTPS URL**: `https://<name>.fd.robertpuffe.com`, with TLS
  terminated at the load balancer. `<name>` comes from `app-manifest.yaml`.
- **Logs**: everything your process writes to stdout/stderr lands in
  CloudWatch Logs automatically.
- **Restart and rollback**: crashed containers are restarted; a deploy whose
  containers fail their health check is rolled back automatically.
- **Health monitoring and alarms**: the platform polls your healthcheck path
  and alarms on sustained CPU or health-check failures.

The app never touches AWS, Terraform, or DNS. Do not add AWS SDK calls for
infrastructure, do not write `.tf` files, do not configure domains or
certificates. If the app spec seems to require any of that, the answer is:
the platform already handles it, or v1 does not support it.

## What the platform expects

Your deliverables are exactly two things: application source code with a
`Dockerfile`, and values in `app-manifest.yaml`. The contract:

1. **Dockerfile at the repo root** that builds a `linux/amd64` image. Do not
   assume the build host's architecture; if you set `--platform` anywhere,
   it must be `linux/amd64`.
2. **Listen on the manifest port.** The process must bind `0.0.0.0` on the
   exact port declared as `port:` in `app-manifest.yaml`. If your framework
   defaults to another port, configure it; the two values must agree.
3. **Healthcheck returns 200 fast.** An HTTP GET to the manifest's
   `healthcheck:` path must return 200 within 30 seconds of container start.
   Keep it dependency-free (no DB calls) so slow starts don't fail deploys.
4. **Log to stdout/stderr only.** No log files, no log shippers, no logging
   agents. Anything written to a file is invisible and lost.
5. **Stateless.** The container filesystem may vanish at any moment (every
   deploy, restart, or scaling event). Never persist anything to local disk
   that must survive a request. v1 has no database or volume support; if the
   spec needs persistence, in-memory state is the v1 answer and data loss on
   restart is accepted.
6. **No privileged operations.** Do not require root at runtime, do not bind
   ports below 1024, do not touch the Docker socket, kernel parameters, or
   host devices. Add a non-root `USER` to the Dockerfile.
7. **All config via env vars** from the manifest's `env:` map. No config
   files baked per environment, no flags that differ between machines. Read
   configuration with sane defaults so the app also runs locally.
8. **NO secrets anywhere.** v1 has no secret support — this is a hard
   constraint, not an inconvenience. No API keys, tokens, passwords, or
   credentials in `env:`, in code, in the Dockerfile, or in the repo. If the
   app spec requires a secret, stop and flag it: the app cannot be built on
   v1 as specced.

## The manifest: `app-manifest.yaml`

The only file with app-specific infrastructure facts. The full v1 schema —
these six fields, nothing else; unknown fields are not read:

```yaml
name: my-app        # becomes the URL host and all AWS resource names
port: 8080          # container port the app listens on
healthcheck: /healthz  # HTTP path returning 200 within 30s of start
cpu: 256            # Fargate CPU units
memory: 512         # MiB
env:                # non-secret config only
  LOG_LEVEL: info
```

Field rules:

- `name`: must match `^[a-z][a-z0-9-]{0,19}$` — lowercase letters, digits,
  hyphens; starts with a letter; at most 20 characters. Deploy fails
  otherwise.
- `port`: integer 1–65535; use an unprivileged port (>= 1024) because the
  container runs as non-root. Must equal the port the process binds.
- `healthcheck`: absolute HTTP path starting with `/`.
- `cpu` / `memory`: must be a valid Fargate pair. Valid pairs (cpu units /
  MiB): 256 with 512, 1024, or 2048; 512 with 1024–4096 (1024-step); 1024
  with 2048–8192 (1024-step). When unsure, use 256/512; it fits almost any
  demo app.
- `env`: flat map of string keys to string values. Non-secret only (rule 8
  above).
- There is deliberately **no `image` field**: CI builds the image and
  injects its reference at deploy time. Never add one.

## Files you must not touch

- `main.tf`
- `.github/workflows/ci.yml`

These are platform boilerplate, pinned to a platform version. Editing either
one takes the app off the platform (spec §4: no escape hatches) — the deploy
is then unsupported and expected to break. Do not add other `.tf` files or
other workflow files either; the pipeline runs exactly one workflow against
exactly one Terraform root.

## Pipeline gates the app must pass

Every push to `main` runs the deploy pipeline. Two scan gates block it, both
failing on HIGH/CRITICAL findings only (a deliberate, documented threshold):

1. **Trivy image scan** on the built container image.
2. **Trivy IaC scan** on the Terraform.

Practical consequence for you: choose current, slim base images
(`*-alpine`, `*-slim`, or distroless) and current dependency versions, AND
upgrade OS packages in the Dockerfile (`apk upgrade --no-cache` /
`apt-get upgrade -y`) — even current official images lag CVE fixes by days,
and the gate fails on fixable HIGH/CRITICAL vulns before your code ever runs.
Also strip package managers your container never invokes at runtime (npm,
pip, etc.): their bundled dependencies carry CVEs too — npm's own
node_modules inside `node:*-alpine` has failed this gate before. Scan
locally before pushing if you can: `trivy image --severity HIGH,CRITICAL <tag>`.

## Worked example

The platform repo carries a running reference app at `examples/hello`
(github.com/rpuffe/flightdeck): an nginx container serving static content at
`https://hello.fd.robertpuffe.com`. Its entire app-side footprint is a
manifest (`name: hello`, `port: 80`, `healthcheck: /`, `cpu: 256`,
`memory: 512`, `env: {}`) plus an image — nothing else was written to deploy
it. (One caveat: hello runs a stock demo image that predates the pipeline
gates and binds port 80 as root. It's grandfathered; your app is not — follow
rule 6 and use a port >= 1024.)

To build a new app from this template, the sequence is:

1. Read the app spec. Write the application source and replace the
   placeholder `Dockerfile` so it satisfies the eight expectations above.
2. Edit `app-manifest.yaml`: set `name` (regex above), `port`,
   `healthcheck`, and any non-secret `env` the app reads. Keep `cpu: 256`,
   `memory: 512` unless the spec demands more.
3. Verify locally: `docker build --platform linux/amd64 -t app . &&
   docker run --rm -p 8080:<port> app`, then confirm
   `curl -f localhost:8080<healthcheck>` returns 200.
4. Commit and push to `main`. The pipeline builds, scans, and deploys; the
   app appears at `https://<name>.fd.robertpuffe.com`.

That is the whole job. If something appears to require more than steps 1–4,
re-read this document — the platform either already provides it or v1
deliberately excludes it.
