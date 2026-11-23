#!/usr/bin/env python3
"""Exhaustive interleaving model of the fleet scaler.

Drives the real bootstrap/lambda/scaler.py handlers against a fake AWS and
explores every order in which the actors that write ECS desiredCount, the
listener rules, and target health can act. Each Lambda invocation is one
indivisible step; everything else (ECS launching and stopping tasks, ALB
health checks, Spot interruption, a visitor's browser) moves one step at a
time between invocations.

The fake AWS implements the semantics the scaler depends on:
- ALB health-checks a target group only while some listener rule forwards to
  it. A detached group reports every target "unused", and reattaching starts
  the checks over.
- ECS launches tasks up to desiredCount, stops tasks above it, and a task
  becomes a registered target only once it is running.
- A request to an app host goes wherever its listener rule points: the app
  target group (served if a target is healthy, else the ALB's 503) or the
  scaler Lambda.

Properties (see .claude/skills/scaler-model/SKILL.md):
  wake-liveness             a visitor who opens wake.<domain>/?svc=app reaches
                            the app itself, from every state it can be in,
                            using only its own page loads and AWS progress
                            (no stop, Spot interruption, or deploy since it
                            started), within MAX_WAKE_STEPS steps
  wake-endpoint-start-only  no HTTP request through the ALB lowers any
                            desiredCount or points a listener rule at the
                            scaler
  action-status-honest      an action invocation that returns status "ok"
                            left every service it names at the requested count
  actions-effective         every action the model drives (including each
                            scaler.tf schedule) changes desiredCount the way
                            its name says somewhere in the explored space, so
                            the other properties cannot pass vacuously

Python stdlib only; run with `make verify-model`.
"""

import argparse
import contextlib
import datetime
import html
import importlib.util
import io
import os
import re
import sys
import types
from collections import deque
from pathlib import Path
from typing import NamedTuple
from urllib.parse import parse_qs, urljoin, urlsplit

ROOT = Path(__file__).resolve().parents[1]
SCALER_PY = ROOT / "bootstrap" / "lambda" / "scaler.py"
SCALER_TF = ROOT / "bootstrap" / "scaler.tf"

DOMAIN = "fd.example.com"
WAKE_HOST = f"wake.{DOMAIN}"
CLUSTER = "flightdeck"
SCALER_TG = "flightdeck-scaler"
LISTENER_ARN = "arn:aws:elasticloadbalancing:us-east-1:1:listener/app/flightdeck/1/1"
LB_ARN = "arn:aws:elasticloadbalancing:us-east-1:1:loadbalancer/app/flightdeck/1"
GHOST = "ghost"  # a name `make stop SVC=...` can be given that is not a service
MAX_WAKE_STEPS = 12

STOP_ACTIONS = {"stop", "stop-all", "sleep-idle"}
START_ACTIONS = {"start", "start-all"}


def tg_name(svc):
    return f"flightdeck-{svc}"


def tg_arn(name):
    return f"arn:aws:elasticloadbalancing:us-east-1:1:targetgroup/{name}/1"


def app_host(svc):
    return f"{svc}.{DOMAIN}"


# ---------------------------------------------------------------------------
# State. Immutable and hashable so the explorer can dedupe it; tasks are
# kept sorted, so two orderings of identical tasks are one state.
# ---------------------------------------------------------------------------


class Task(NamedTuple):
    running: bool  # registered as a target once running
    passed_checks: bool  # ALB health checks passed while the group was attached
    old: bool  # created more than IDLE_SLEEP_MINUTES ago


class Service(NamedTuple):
    name: str
    desired: int
    tasks: tuple


class Visitor(NamedTuple):
    phase: str  # idle | at | served | stranded
    url: str = ""
    disturbed: bool = False  # a stop, Spot interruption, or deploy hit since it started


class State(NamedTuple):
    services: tuple
    rules: tuple  # sorted (host, target group name) pairs on the HTTPS listener
    visitor: Visitor


IDLE = Visitor("idle")


def initial_state(names):
    """What terraform apply leaves: one healthy task per service, each app
    host forwarding to its own target group, wake host to the scaler."""
    healthy = (Task(True, True, False),)
    rules = {WAKE_HOST: SCALER_TG, **{app_host(n): tg_name(n) for n in names}}
    return State(
        tuple(Service(n, 1, healthy) for n in names),
        tuple(sorted(rules.items())),
        IDLE,
    )


# ---------------------------------------------------------------------------
# Mutable world the fake boto3 clients read and write during one invocation.
# ---------------------------------------------------------------------------


class World:
    def __init__(self, state):
        self.desired = {s.name: s.desired for s in state.services}
        self.tasks = {s.name: list(s.tasks) for s in state.services}
        self.rules = dict(state.rules)

    def freeze(self, visitor):
        services = tuple(
            Service(n, self.desired[n], tuple(sorted(self.tasks[n]))) for n in sorted(self.desired)
        )
        return State(services, tuple(sorted(self.rules.items())), visitor)

    def attached(self, group):
        return group in self.rules.values()

    def forward(self, host, group):
        self.rules[host] = group
        for svc, tasks in self.tasks.items():
            if not self.attached(tg_name(svc)):
                self.tasks[svc] = [t._replace(passed_checks=False) for t in tasks]

    def healthy(self, svc):
        return self.attached(tg_name(svc)) and any(t.running and t.passed_checks for t in self.tasks[svc])


class AwsError(Exception):
    pass


WORLD = None  # the World the current invocation sees


class FakeEcs:
    class _Paginator:
        def paginate(self, cluster):
            assert cluster == CLUSTER
            return [{"serviceArns": [f"arn:aws:ecs:us-east-1:1:service/{CLUSTER}/{n}" for n in sorted(WORLD.desired)]}]

    def get_paginator(self, op):
        assert op == "list_services", op
        return self._Paginator()

    def describe_services(self, cluster, services):
        out = []
        for arn in services:
            name = arn.rsplit("/", 1)[-1]
            if name in WORLD.desired:
                running = sum(t.running for t in WORLD.tasks[name])
                out.append({"serviceName": name, "desiredCount": WORLD.desired[name], "runningCount": running})
        return {"services": out}

    def update_service(self, cluster, service, desiredCount):
        if service not in WORLD.desired:
            raise AwsError(f"ServiceNotFoundException: {service}")
        WORLD.desired[service] = desiredCount

    def list_tasks(self, cluster, serviceName):
        return {"taskArns": [f"task/{serviceName}/{i}" for i in range(len(WORLD.tasks.get(serviceName, [])))]}

    def describe_tasks(self, cluster, tasks):
        now = datetime.datetime.now(datetime.timezone.utc)
        out = []
        for arn in tasks:
            _, svc, index = arn.split("/")
            task = WORLD.tasks[svc][int(index)]
            created = now - datetime.timedelta(days=1) if task.old else now
            out.append({"taskArn": arn, "createdAt": created})
        return {"tasks": out}


class FakeElb:
    def _groups(self):
        return {SCALER_TG, *(tg_name(n) for n in WORLD.desired)}

    def describe_rules(self, ListenerArn):
        assert ListenerArn == LISTENER_ARN
        return {
            "Rules": [
                {
                    "RuleArn": f"rule/{host}",
                    "Conditions": [{"Field": "host-header", "HostHeaderConfig": {"Values": [host]}}],
                    "Actions": [{"Type": "forward", "TargetGroupArn": tg_arn(group)}],
                }
                for host, group in sorted(WORLD.rules.items())
            ]
        }

    def modify_rule(self, RuleArn, Actions):
        host = RuleArn.removeprefix("rule/")
        (action,) = Actions
        WORLD.forward(host, action["TargetGroupArn"].split("/")[-2])

    def describe_target_groups(self, Names):
        unknown = [n for n in Names if n not in self._groups()]
        if unknown:
            raise AwsError(f"TargetGroupNotFound: {unknown}")
        return {
            "TargetGroups": [
                {
                    "TargetGroupName": n,
                    "TargetGroupArn": tg_arn(n),
                    "LoadBalancerArns": [LB_ARN] if WORLD.attached(n) else [],
                }
                for n in Names
            ]
        }

    def describe_target_health(self, TargetGroupArn):
        group = TargetGroupArn.split("/")[-2]
        svc = group.removeprefix("flightdeck-")
        attached = WORLD.attached(group)
        out = []
        for t in WORLD.tasks.get(svc, []):
            if not t.running:
                continue
            state = ("healthy" if t.passed_checks else "initial") if attached else "unused"
            out.append({"TargetHealth": {"State": state}})
        return {"TargetHealthDescriptions": out}


class FakeCloudWatch:
    def get_metric_data(self, MetricDataQueries, StartTime, EndTime):
        # Nobody but the modelled visitor uses the apps, and its own page
        # loads never reach the idle check (sleep-idle is a stop actor).
        return {"MetricDataResults": [{"Id": q["Id"], "Values": [0.0]} for q in MetricDataQueries]}


def load_scaler():
    os.environ.update(
        CLUSTER=CLUSTER,
        APP_DOMAIN=DOMAIN,
        IDLE_SLEEP_MINUTES="30",
        LISTENER_ARN=LISTENER_ARN,  # read by the 943876b-era rule-flip code
        SCALER_TG_ARN=tg_arn(SCALER_TG),
    )
    clients = {"ecs": FakeEcs(), "elbv2": FakeElb(), "cloudwatch": FakeCloudWatch()}
    sys.modules["boto3"] = types.SimpleNamespace(client=lambda name: clients[name])
    sys.dont_write_bytecode = True  # keep __pycache__ out of the Lambda source dir
    spec = importlib.util.spec_from_file_location("scaler_under_model", SCALER_PY)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def scheduled_actions():
    """Every {"action": ...} payload an aws_scheduler_schedule in scaler.tf
    sends. A new schedule action must be classified here before the model
    will run, so a new writer of desiredCount cannot slip past it."""
    text = SCALER_TF.read_text(encoding="utf-8")
    actions = set()
    for block in re.split(r'(?m)^resource "', text):
        if block.startswith('aws_scheduler_schedule"'):
            actions.update(re.findall(r'\baction\s*=\s*"([^"]+)"', block))
    unknown = actions - STOP_ACTIONS - START_ACTIONS
    if unknown:
        raise SystemExit(f"scaler.tf schedules unclassified actions {sorted(unknown)}: add them to STOP_ACTIONS or START_ACTIONS")
    return sorted(actions)


# ---------------------------------------------------------------------------
# Transitions
# ---------------------------------------------------------------------------


class Edge(NamedTuple):
    label: str
    kind: str  # visitor | aws | stop | start | deploy | probe | arrive | leave
    target: State
    violation: str | None  # set when this step breaks a safety property


LIVENESS_KINDS = {"visitor", "aws"}
DISTURBING_KINDS = {"stop", "deploy"}  # plus Spot interruption, kind "stop"


class Model:
    def __init__(self, names):
        self.names = names
        self.scaler = load_scaler()
        self.schedules = scheduled_actions()
        self.effects = {}  # action -> {"lowered", "raised"} seen on some edge

    def invoke(self, state, event):
        global WORLD
        WORLD = World(state)
        with contextlib.redirect_stdout(io.StringIO()):
            response = self.scaler.lambda_handler(event, None)
        world, WORLD = WORLD, None
        return world, response

    def http(self, state, url):
        """One request through the ALB. Returns (world after, outcome) where
        outcome is ("app",), ("status", code), or ("page", code, refresh_url)."""
        parts = urlsplit(url)
        host = parts.hostname
        group = dict(state.rules).get(host)
        if group is None:
            return World(state), ("status", 404)  # listener default action
        if group != SCALER_TG:
            world = World(state)
            svc = group.removeprefix("flightdeck-")
            return world, ("app",) if world.healthy(svc) else ("status", 503)
        query = {k: v[0] for k, v in parse_qs(parts.query).items()}
        event = {
            "requestContext": {"elb": {"targetGroupArn": tg_arn(SCALER_TG)}},
            "httpMethod": "GET",
            "path": parts.path or "/",
            "headers": {"host": host},
            "queryStringParameters": query,
        }
        world, response = self.invoke(state, event)
        match = re.search(r'http-equiv="refresh" content="\d+;url=([^"]*)"', response.get("body", ""))
        refresh = urljoin(url, html.unescape(match.group(1))) if match else None
        # ALB answers 502 when the Lambda's reply is not an HTTP response.
        return world, ("page", response.get("statusCode", 502), refresh)

    def checked_http(self, state, url):
        """self.http plus the wake-endpoint-start-only check on its effect."""
        world, outcome = self.http(state, url)
        before = {s.name: s.desired for s in state.services}
        lowered = [n for n, d in world.desired.items() if d < before[n]]
        to_scaler = [h for h, g in world.rules.items() if g == SCALER_TG and dict(state.rules)[h] != SCALER_TG]
        violation = None
        if lowered or to_scaler:
            violation = (
                "wake-endpoint-start-only: HTTP request "
                f"{url} lowered desiredCount of {lowered} / pointed {to_scaler} at the scaler"
            )
        return world, outcome, violation

    def successors(self, state):
        yield from self.visitor_steps(state)
        yield from self.probe_steps(state)
        yield from self.action_steps(state)
        yield from self.deploy_steps(state)
        yield from self.ecs_steps(state)

    def visitor_steps(self, state):
        v = state.visitor
        if v.phase == "idle":
            url = f"https://{WAKE_HOST}/?svc={self.names[0]}"
            yield Edge(f"visitor opens {url}", "arrive", state._replace(visitor=Visitor("at", url)), None)
            return
        if v.phase in ("served", "stranded"):
            yield Edge("visitor leaves", "leave", state._replace(visitor=IDLE), None)
            return
        world, outcome, violation = self.checked_http(state, v.url)
        if outcome == ("app",):
            nxt, what = Visitor("served", v.url, v.disturbed), "the app itself"
        elif outcome[0] == "page" and outcome[2]:
            nxt, what = Visitor("at", outcome[2], v.disturbed), f"a {outcome[1]} page refreshing to {outcome[2]}"
        else:
            nxt, what = Visitor("stranded", v.url, v.disturbed), f"HTTP {outcome[1]} with no way forward"
        yield Edge(f"visitor loads {v.url} -> {what}", "visitor", world.freeze(nxt), violation)

    def probe_steps(self, state):
        """Anyone on the internet: every query shape the wake host parses,
        plus a direct visit to each app host."""
        urls = [
            f"https://{WAKE_HOST}/",
            f"https://{WAKE_HOST}/?svc=all",
            f"https://{WAKE_HOST}/?action=stop-all",
            f"https://{WAKE_HOST}/?svc={self.names[0]}&action=stop",
            f"https://{WAKE_HOST}/?svc={GHOST}",
            *(f"https://{app_host(n)}/" for n in self.names),
        ]
        for url in urls:
            world, _, violation = self.checked_http(state, url)
            yield Edge(f"someone requests {url}", "probe", world.freeze(state.visitor), violation)

    def action_steps(self, state):
        invocations = [("scheduler", {"action": a, "services": list(self.names)} if a == "start" else {"action": a}) for a in self.schedules]
        for name in (*self.names, GHOST):
            invocations.append(("make stop", {"action": "stop", "services": [name]}))
            invocations.append(("make start", {"action": "start", "services": [name]}))
        invocations.append(("make stop-all", {"action": "stop-all"}))
        invocations.append(("make start-all", {"action": "start-all"}))
        for who, event in invocations:
            action = event["action"]
            world, response = self.invoke(state, event)
            kind = "stop" if action in STOP_ACTIONS else "start"
            seen = self.effects.setdefault(action, set())
            for svc in state.services:
                if world.desired[svc.name] != svc.desired:
                    seen.add("lowered" if world.desired[svc.name] < svc.desired else "raised")
            violation = None
            if action in ("stop", "start", "stop-all", "start-all") and response.get("status") == "ok":
                target = 0 if action.startswith("stop") else 1
                named = event.get("services") or sorted(world.desired)
                wrong = [n for n in named if world.desired.get(n) != target]
                if wrong:
                    violation = f"action-status-honest: {event} returned status ok but {wrong} is not at desiredCount={target}"
            yield Edge(f"{who} invokes the scaler with {event}", kind, self.after(state, world, kind), violation)

    def deploy_steps(self, state):
        for n in self.names:
            world = World(state)
            world.desired[n] = 1
            world.forward(app_host(n), tg_name(n))
            yield Edge(f"terraform apply of {n} (desired_count=1, listener rule -> {tg_name(n)})", "deploy", self.after(state, world, "deploy"), None)

    def ecs_steps(self, state):
        for svc in state.services:
            n = svc.name
            tasks = list(svc.tasks)

            def edge(label, kind, new_tasks):
                world = World(state)
                world.tasks[n] = new_tasks
                return Edge(f"{n}: {label}", kind, self.after(state, world, kind), None)

            if len(tasks) < svc.desired:
                yield edge("ECS launches a task", "aws", tasks + [Task(False, False, False)])
            attached = tg_name(n) in dict(state.rules).values()
            for i, t in enumerate(tasks):
                rest = tasks[:i] + tasks[i + 1 :]
                if not t.running:
                    yield edge("task reaches RUNNING and registers with its target group", "aws", rest + [t._replace(running=True)])
                if t.running and attached and not t.passed_checks:
                    yield edge("ALB health checks pass", "aws", rest + [t._replace(passed_checks=True)])
                if t.running and not t.old:
                    yield edge("task outlives the idle window", "aws", rest + [t._replace(old=True)])
                if len(tasks) > svc.desired:
                    yield edge("ECS stops a task above desiredCount", "aws", rest)
                if t.running:
                    yield edge("Spot interruption kills a task", "stop", rest)

    def after(self, state, world, kind):
        v = state.visitor
        if v.phase == "at" and kind in DISTURBING_KINDS:
            lowered = any(world.desired[s.name] < s.desired or len(world.tasks[s.name]) < len(s.tasks) for s in state.services)
            if lowered or kind == "deploy":
                v = v._replace(disturbed=True)
        return world.freeze(v)


# ---------------------------------------------------------------------------
# Exploration and checking
# ---------------------------------------------------------------------------


def explore(model):
    init = initial_state(model.names)
    parent = {init: None}
    edges = {}
    queue = deque([init])
    while queue:
        s = queue.popleft()
        out = list(model.successors(s))
        edges[s] = out
        for e in out:
            if e.target not in parent:
                parent[e.target] = (s, e)
                queue.append(e.target)
    return init, parent, edges


def path_to(parent, state):
    steps = []
    while parent[state] is not None:
        prev, edge = parent[state]
        steps.append(edge)
        state = prev
    return list(reversed(steps))


def render(state):
    rules = dict(state.rules)
    parts = []
    for s in state.services:
        group = rules.get(app_host(s.name))
        attached = tg_name(s.name) in rules.values()
        tasks = ",".join(
            ("healthy" if t.passed_checks and attached else "running" if t.running else "pending") + ("/old" if t.old else "")
            for t in s.tasks
        ) or "none"
        route = "app target group" if group == tg_name(s.name) else "scaler Lambda"
        health = "health-checked" if attached else "detached, targets 'unused'"
        parts.append(f"{s.name}: desired={s.desired} tasks=[{tasks}] rule->{route} ({health})")
    v = state.visitor
    parts.append(f"visitor {v.phase}{' ' + v.url if v.url else ''}{' (disturbed)' if v.disturbed else ''}")
    return "; ".join(parts)


def trace(parent, state):
    steps = path_to(parent, state)
    start = state
    while parent[start] is not None:
        start = parent[start][0]
    lines = [f"   0. start: {render(start)}"]
    for i, e in enumerate(steps, 1):
        lines.append(f"  {i:2}. {e.label}")
        lines.append(f"      => {render(e.target)}")
    return "\n".join(lines)


def check_safety(parent, edges, prop):
    for s in parent:
        for e in edges[s]:
            if e.violation and e.violation.startswith(prop):
                return f"{e.violation}\n\nShortest trace:\n{trace(parent, s)}\n  >>> {e.label}\n      => {render(e.target)}"
    return None


def check_liveness(parent, edges):
    """Every reachable state with an undisturbed visitor in flight must reach
    'served' within MAX_WAKE_STEPS using only visitor and AWS steps. A
    visitor stranded on a dead end without being disturbed is in flight with
    nowhere to go."""
    back = {}
    for s, out in edges.items():
        for e in out:
            if e.kind in LIVENESS_KINDS:
                back.setdefault(e.target, []).append(s)
    dist = {s: 0 for s in parent if s.visitor.phase == "served"}
    queue = deque(dist)
    while queue:
        s = queue.popleft()
        for p in back.get(s, []):
            if p not in dist:
                dist[p] = dist[s] + 1
                queue.append(p)
    inflight = [s for s in parent if s.visitor.phase in ("at", "stranded") and not s.visitor.disturbed]
    stuck = [s for s in inflight if dist.get(s, MAX_WAKE_STEPS + 1) > MAX_WAKE_STEPS]
    worst = max((dist[s] for s in inflight if s in dist), default=0)
    if not stuck:
        return None, worst
    s = stuck[0]  # parent is in BFS order, so this has the shortest trace
    if s.visitor.phase == "stranded":
        return (
            f"wake-liveness: a visitor waking the app was left on a dead end at {s.visitor.url}\n"
            f"with no stop, Spot interruption, or deploy since it opened the wake page.\n\n"
            f"Shortest trace:\n{trace(parent, s)}"
        ), worst
    reason = "can never" if s not in dist else f"needs {dist[s]} steps (bound {MAX_WAKE_STEPS}) to"
    return (
        f"wake-liveness: from the last state below, a visitor waking the app {reason} reach it.\n\n"
        f"Shortest trace to that state:\n{trace(parent, s)}\n\n"
        f"From there, with only the visitor's page loads and AWS progress (no stop, Spot\n"
        f"interruption, or deploy), {len(closure(s, edges))} states are reachable and none serves the app.\n"
        f"One run that goes on forever, AWS progress first:\n{lasso(s, edges)}"
    ), worst


def closure(start, edges):
    seen, queue = {start}, deque([start])
    while queue:
        for e in edges[queue.popleft()]:
            if e.kind in LIVENESS_KINDS and e.target not in seen:
                seen.add(e.target)
                queue.append(e.target)
    return seen


def lasso(start, edges, limit=16):
    lines, seen, cur = [], {start}, start
    for _ in range(limit):
        options = [e for e in edges[cur] if e.kind in LIVENESS_KINDS]
        if not options:
            lines.append("      (no step left)")
            break
        fresh = [e for e in options if e.target not in seen]
        e = (sorted(fresh, key=lambda e: e.kind != "aws") or [o for o in options if o.kind == "visitor"] or options)[0]
        lines.append(f"      - {e.label}\n        => {render(e.target)}")
        if e.target in seen:
            lines.append("      (back to an earlier state: the loop repeats)")
            break
        seen.add(e.target)
        cur = e.target
    return "\n".join(lines)


def check_actions_effective(model):
    """Guards the model against passing vacuously: every action it drives
    must change desiredCount in the direction its name promises somewhere in
    the explored space. A stop that never stops (a broken dispatch, a fake
    AWS the code no longer fits) would otherwise make every property pass."""
    missing = []
    for action, seen in sorted(model.effects.items()):
        want = "lowered" if action in STOP_ACTIONS else "raised"
        if want not in seen:
            missing.append(f"{action} never {want} any desiredCount")
    return "actions-effective: " + "; ".join(missing) if missing else None


PROPERTIES = ("wake-liveness", "wake-endpoint-start-only", "action-status-honest", "actions-effective")


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--property", action="append", choices=PROPERTIES, help="check only these (default: all)")
    parser.add_argument("--services", type=int, default=2, help="services in the cluster (default 2)")
    args = parser.parse_args()
    props = args.property or list(PROPERTIES)
    names = ("app", "web", "api", "docs")[: args.services]

    model = Model(names)
    _, parent, edges = explore(model)
    print(f"scaler model: {len(parent)} states, {sum(map(len, edges.values()))} transitions, services={list(names)}, schedules={model.schedules}")
    failed = False
    for prop in props:
        if prop == "wake-liveness":
            problem, worst = check_liveness(parent, edges)
            detail = f"worst case {worst} steps to the app" if not problem else ""
        elif prop == "actions-effective":
            problem, detail = check_actions_effective(model), ""
        else:
            problem, detail = check_safety(parent, edges, prop), ""
        if problem:
            failed = True
            print(f"FAIL {prop}\n{problem}\n")
        else:
            print(f"ok   {prop}{' (' + detail + ')' if detail else ''}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
