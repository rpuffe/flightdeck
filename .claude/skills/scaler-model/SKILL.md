---
name: scaler-model
description: Model-check the fleet scaler (bootstrap/lambda/scaler.py, bootstrap/scaler.tf) by exploring every interleaving of its actors against a fake AWS. Use before changing anything that writes ECS desiredCount, ALB listener rules, or the wake page's refresh flow, when a schedule is added to scaler.tf, when reviving auto-wake (issue #35), or when `make verify-model` fails.
---

# Scaler model

`checks/scaler_model.py` imports the real `bootstrap/lambda/scaler.py`,
replaces boto3 with a fake AWS, and does a breadth-first search over every
order in which these actors can act on one cluster of two services
(`app`, `web`):

- a visitor's browser opening `wake.<domain>/?svc=app` and following each
  meta-refresh, one page load per step
- every schedule in `bootstrap/scaler.tf` (read from the file:
  `stop-all`, `sleep-idle`, morning `start`)
- `make stop` / `make start` for each service and for a nonexistent name,
  `make stop-all`, `make start-all`
- a `terraform apply` of either service (desired_count=1, listener rule back
  on its own target group)
- anyone requesting the wake host with each query shape it parses, or an app
  host directly
- ECS launching a task, the task reaching RUNNING, ALB health checks
  passing, a task aging past the idle window, ECS stopping a task above
  desiredCount, Spot interruption

Each Lambda invocation is one indivisible step. That matches neither
reality nor the code exactly: a handler makes several AWS calls, and the
Lambda can run concurrently with itself. Races inside one invocation (the
sleep-idle check-then-stop window, for example) are out of scope.

## Properties

Each one fails with a counterexample written as numbered steps in the code's
own terms (actor, event payload, resulting desired count, rule target,
target health, visitor URL).

- **wake-liveness.** A visitor who opens the wake page for an app reaches the
  app itself, from every state its visit can be in, using only its own page
  loads and AWS progress, within 12 steps, unless a stop, Spot interruption,
  or deploy hit since it started. Harm: a visitor stranded on a warming loop
  or a raw 503. Catches the 943876b deadlock (the rule flip detached the app
  target group, which ALB then never health-checks) and the 2531b96^ blind
  20s redirect into a cold start.
- **wake-endpoint-start-only.** No HTTP request through the ALB lowers any
  desiredCount or points a listener rule at the scaler. Harm: anyone on the
  internet could stop the fleet.
- **action-status-honest.** A `start`/`stop`/`start-all`/`stop-all` invocation
  that returns status `ok` left every named service at the requested count.
  Harm: `make stop` and the ActionErrors alarm miss failures. Catches 61381fc^.
- **actions-effective.** Every action the model drives lowers or raises
  some desiredCount somewhere in the explored space. Harm it prevents: the
  other three passing vacuously because a handler stopped doing anything
  against the fake.

## Run it

```sh
make verify-model                       # all properties, ~0.3 s
python3 checks/scaler_model.py --property wake-liveness
python3 checks/scaler_model.py --services 3   # bigger cluster, slower
python3 scripts/prove_checks.py scaler-auto-wake-deadlock scaler-model-blind-redirect scaler-model-status-ok-on-failure
```

platform-ci runs `make verify-model` and `make prove-checks`. The three
registry entries in `checks/regressions/` overlay the old `scaler.py` (and
`scaler.tf` for 943876b) and require the model to fail with the matching
counterexample.

## Does my change touch the verified code?

Yes if it edits `bootstrap/lambda/scaler.py`, the `aws_scheduler_schedule`
blocks or Lambda environment in `bootstrap/scaler.tf`, the listener rule or
`desired_count` in `modules/fargate-service/main.tf`, or the `stop`/`start`
targets in the `Makefile`. Run `make verify-model` before committing.

## A failure: bug or modeling error?

Read the trace first. Then decide which side is wrong:

- **The fake AWS is wrong** when a step does something real AWS would not:
  a call signature the fake rejects but AWS accepts, a response field the
  fake omits, an ordering ECS or ALB cannot produce. Fix `FakeEcs`,
  `FakeElb`, `FakeCloudWatch`, or `ecs_steps`, and say which AWS behavior you
  matched. A Python traceback out of a fake client (TypeError on a keyword,
  KeyError on a response field) is almost always this: the code started
  calling an API the fake does not implement yet. Implement it with real
  AWS semantics.
- **The code is wrong** when every step is something AWS and the actors
  really do. Report it with the trace. Do not weaken a property, shrink the
  actor set, or mark a disruptor as harmless to make it pass, and do not
  change `scaler.py` unless that is the task.
- `scaler.tf schedules unclassified actions` means a new schedule appeared.
  Add its action to `STOP_ACTIONS` or `START_ACTIONS` in the model; a stop
  action must also be handled by the scaler or actions-effective fails.

## Updating the model for an intended change

- A new AWS call in `scaler.py`: add it to the matching fake client with
  AWS's semantics, including the error AWS raises for unknown names.
- A new actor (a schedule, a make target, an ECS behavior): add it to
  `action_steps`, `ecs_steps`, or `deploy_steps` with the right kind. Kind
  `stop` marks a visitor disturbed; kinds `visitor` and `aws` are the only
  ones wake-liveness lets the visitor rely on.
- Reviving auto-wake on direct visit (issue #35): add a second visitor entry
  that opens `https://app.<domain>/` directly, and keep the ALB rule that a
  detached target group is never health-checked. Any design must pass
  wake-liveness with that rule in place.
- After the model passes, also run the scratch-break check below once, then
  move the sync commit.

## Proving the check still bites

Copy `checks/scaler_model.py`, `bootstrap/scaler.tf`, and
`bootstrap/lambda/scaler.py` into a scratch directory with the same layout,
break the scratch `scaler.py`, and run the model there. Each of these must
fail the named property:

- in `_wake_response`, set `poll_url` to the app's own URL: wake-liveness
  (dead end at `https://app.`)
- in `_handle_wake_host`, replace the 400 for `action` with
  `return _handle_action_event({"action": query["action"], "services": [query.get("svc")]})`:
  wake-endpoint-start-only
- rename the `sleep-idle` branch in `_handle_action_event`: actions-effective

## Coverage record

- `bootstrap/lambda/scaler.py`: `lambda_handler`, `_handle_alb_event`,
  `_handle_wake_host`, `_wake_response`, `_wake_all_response`,
  `_index_response`, `_handle_action_event`, `_handle_sleep_idle` and the ECS,
  ELB, and CloudWatch helpers they call. Not covered: HTML escaping (unit
  tests in `tests/test_scaler.py`), sleep-idle's request-count and window
  arithmetic (the fake reports zero requests and tasks as either brand new
  or a day old), describe_services chunking above 10 services.
- `bootstrap/scaler.tf`: the `action` of every `aws_scheduler_schedule`.
- Bounds: 2 services, at most one task each, one visitor, desiredCount 0 or 1.

Last confirmed to describe the code at commit `9f32db6`. Move this forward
only after `make verify-model` passes and the scratch breaks above still
fail at the new commit.
