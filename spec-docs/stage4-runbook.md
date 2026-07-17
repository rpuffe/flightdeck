# Stage 4 runbook — cross-agent compatibility test

Same spec, same contract, different coding agents. The platform must not
change unless a failure is a platform bug (spec §8, Stage 4). Results land
in the README compatibility table.

## Protocol (per agent under test)

1. **Onboard a fresh app** (platform side, ~2 min):
   - Pick a name (dns-safe, ≤20 chars — e.g. `chores` for Cursor).
   - Create the repo from `template-app/` contents plus `APP_SPEC.md`
     (copy spec-docs/todo-app-spec.md, retitle, change the default greeting
     string so each agent's deploy is distinguishable).
   - Add it to the `apps` registry and add its numeric GitHub repository ID to
     `github_repository_ids` in `bootstrap/variables.tf`; run `make bootstrap`
     (ECR repositories plus the exact repository-specific OIDC role).
   - Set the repo variable `FLIGHTDECK_DEPLOY_ROLE_ARN` (value:
     `terraform -chdir=bootstrap output -raw deploy_role_arn`).
   - Push the baseline. (The baseline push triggers one failing noise run
     under the placeholder manifest name — expected, ignore it.)
2. **Hand off cold.** Open the repo in the agent under test with NO other
   context. The kickoff prompt is standardized:
   > Build and ship the application described in APP_SPEC.md. AGENTS.md is
   > the platform contract — follow it and whatever it points to. Pushes to
   > main deploy automatically. You are done when the live URL serves the
   > spec'd behavior, verified with curl.
3. **Start the clock** at prompt submission. Stop at the first independently
   verified 200 serving spec behavior at `https://<name>.fd.robertpuffe.com`.
4. **Record without helping.** Note every preflight failure, pipeline
   failure, contract violation (edited main.tf/ci.yml?), and whether the
   agent used `make preflight` unprompted. Do not assist unless hard-stuck;
   if assistance was needed, the run is a FAIL with notes.
5. **Classify each failure**: agent error (app-side fix) / contract gap
   (patch template docs) / platform bug (fix platform — the only case where
   platform changes are allowed in Stage 4).

## Table row format (README)

| Agent | Result | Time | CI failures | Local (preflight) catches | Notes |

Baselines already recorded: Claude Code (Sonnet) — v0.1.x monolith 8m18s /
1 CI failure; v0.2.0 contract 6m38s / 0 CI failures.

## Candidate agents

- Cursor (spec-named).
- One other: Codex CLI, Copilot Workspace, or similar — whatever is at hand.
  AGENTS.md is the cross-tool convention most of them read natively.
