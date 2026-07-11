# Worked example

Read this for a concrete reference of what "done" looks like.

**github.com/rpuffe/todo**, live at `https://todo.fd.robertpuffe.com`
(promoted to prod via a `v*` tag after `https://todo-dev.fd.robertpuffe.com`
proved out on `main`). Built by a coding agent from a spec + this contract,
in one session:

- Zero-dependency `node:22-alpine` API.
- Manifest sets one env var: `GREETING`.
- One pipeline gate failure, fixed without help: npm's own bundled
  dependencies tripped the image scan gate even though the app has zero npm
  dependencies. Fixed by stripping npm/npx/corepack from the image — see
  `docs/dockerfile.md`.

Also see `examples/hello` in the platform repo
(github.com/rpuffe/flightdeck): the minimal case, manifest only, no app
code — a static nginx site. Caveat: `hello` predates the scan gates and
runs as root on port 80; it's grandfathered, not a pattern to copy — your
app needs a non-root user and a port >= 1024 (`docs/contract.md`, rule 6).

For a `storage: s3` worked example, once built, see the arcade app spec'd at
`spec-docs/arcade-app-spec.md` in the platform repo — the first app whose
data must survive restarts.

## Build sequence

1. Write the app + Dockerfile against `docs/contract.md` and
   `docs/dockerfile.md`.
2. Set `app-manifest.yaml` (`name`, `port`, `healthcheck`, `env`).
3. `make preflight` — fix anything it flags before pushing.
4. Push to `main` → dev. The pipeline builds, scans, and deploys to
   `https://<name>-dev.fd.robertpuffe.com`; if it fails, `docs/pipeline.md`
   has the playbook.
5. Tag `v*` on that same commit to promote it to prod, unchanged. See
   `docs/pipeline.md` for the promotion rule.
