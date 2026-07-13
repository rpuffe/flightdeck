# Flightdeck threat model

Flightdeck is a production-minded reference platform running in one personal
AWS account. It demonstrates production-shaped controls and deployment
semantics; it is not presented as a turnkey production platform or a tenant
isolation boundary. In particular, `prod` names a promotion target, not a claim
that the workload meets every organization's production requirements.

## Scope and trust boundaries

**Protected assets:** the existing AWS account and parent DNS zone, Terraform
state, the GitHub OIDC deploy roles, built container images, per-app data, and
the shared Flightdeck network and load balancer.

**Trusted actors and systems:** the human applying the account bootstrap, each
explicitly registered GitHub repository's `main` branch and `v*` tags, pinned
Flightdeck releases, Terraform and GitHub Actions dependencies, and application
code merged to a trusted ref.

**Untrusted inputs:** pull-request code, public HTTP traffic, app manifest
values before validation, container dependencies, and application data.
Application code remains responsible for its own authentication,
authorization, input validation, and data handling.

## Controls and residual risk

| Area | Implemented control | Residual risk / production hardening |
|---|---|---|
| AWS account boundary | Terraform creates net-new `flightdeck-` resources with default `project=flightdeck` tags. Destroy operations target Flightdeck state; the existing parent zone is read-only except for one NS delegation record. | Bootstrap still runs in an existing account. Human review of the bootstrap plan and state location remains mandatory. |
| CI identity | GitHub Actions uses OIDC; no long-lived AWS keys are stored. Pull requests receive no AWS credentials. Each registered repository has an exact-repository role trusted only for `main` and `v*` refs. | The same app role can deploy both dev and prod. Protected tags and a separately approved production role/environment remain roadmap hardening. |
| Deploy authorization | Each app role is scoped to that app's named resources wherever AWS supports resource-level authorization, including task-definition registration. Task and execution roles require an app-specific permissions boundary; deploy roles cannot remove it or create arbitrary inline role policies. `iam:PassRole` is limited to the app's exact roles and ECS tasks. | AWS cannot resource-scope task-definition reads or deregistration. Reads expose cross-app task metadata; deregistration is action- and region-bounded but could affect another app's task-definition revision in the account. AWS also cannot cleanly distinguish one app's rules on the shared ALB listener. Security-group mutation relies on Flightdeck tags, so this is not a hostile-tenant boundary. |
| Terraform state | Each app role can write and lock only its own dev/prod state keys. Bootstrap state is read-only because app stacks consume its shared outputs. | All states remain in one bucket, and every app can read shared bootstrap topology. Separate state buckets and output publication would provide a stronger boundary if real tenancy required it. |
| Pull-request gate | PRs build the image, scan image and Terraform configuration, and run Terraform format/validation without cloud access. HIGH/CRITICAL findings fail; image findings without fixes are ignored deliberately. | Scanning reduces known-risk exposure but is not proof of safety. Actions use version tags rather than commit SHAs; there is no signing, provenance attestation, or SBOM gate. |
| Artifact promotion | Images use immutable commit-SHA tags. A `v*` tag copies the already-scanned OCI manifest from the dev repository to prod, verifies identical digests, and deploys it without rebuilding. Prod retains every tagged image independently of bounded dev churn. | A tag triggers an unconditional, auto-approved production apply. A real production setup should add protected tags and a GitHub Environment approval or equivalent change control. Signing, provenance, and an SBOM gate remain roadmap items. |
| Runtime isolation | Tasks have no public IP, accept ingress only from the shared ALB, and receive no AWS permissions by default. Optional S3 access is scoped to the app's own environment bucket and capped by its boundary. | Tasks share a VPC, cluster, ALB, and NAT egress. Outbound traffic is unrestricted through NAT. This is workload separation for a personal platform, not hostile multi-tenant isolation. |
| Public edge | TLS terminates at the shared ALB with host-based routing; services expose only their declared health and application paths through that ALB. | There is no WAF, rate limiting, DDoS-specific policy beyond AWS defaults, or platform-provided application authentication. Public endpoint abuse remains an application and account-cost risk. |
| Secrets and data | The manifest accepts non-secret environment values only. S3 storage, when requested, is private and encrypted at rest with a narrowly scoped task policy. | There is no secrets injection. The optional bucket is teardown-first (`force_destroy`, no versioning), so it is unsuitable for valuable production data without backup, retention, and recovery controls. |
| Availability and operations | ECS deployment rollback is enabled; health checks, logs, metric alarms, a budget alarm, and explicit stop/start controls exist. | Services run one task, fck-nat is a single-instance cost tradeoff, service alarms have no notification actions, and there are no SLOs, canaries, tested disaster recovery, or full day-2 operations. Sleeping services may be unavailable until explicitly woken or redeployed. |

## Accepted v1 posture

Flightdeck optimizes for a low-cost, inspectable reference platform: one web
service shape, one personal account, standard tools, reversible Terraform, and
measured spec-to-URL runs. The shared control plane, same-app dev/prod role,
single-task availability, automatic tag promotion, and teardown-first storage
are accepted constraints for that purpose, not defaults recommended for a
business production environment.

The roadmap in [the spec](flightdeck-spec.md#11-roadmap--v2-and-beyond-parking-lot)
contains deeper operational features. Security hardening should be driven by a
real workload and threat, without adding speculative manifest fields or
weakening the binding non-goals and existing-account safeguards.
