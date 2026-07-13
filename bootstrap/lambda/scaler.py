"""flightdeck-scaler: nightly cool-down + ALB wake / auto-wake endpoint.

Two entrypoints share this one function (spec 5b: net-new, flightdeck-
prefixed, no speculative surface area):

1. Scheduler / direct-invoke events: {"action": ..., "services": [...]}.
   Drives ECS desired_count for the flightdeck cluster. Used by the nightly
   EventBridge Scheduler rule (action=stop-all), `make
   stop`/`make start`/`make stop-all`/`make start-all`, and any other direct
   invoke. Stop actions ONLY set desired_count to 0 -- they no longer touch
   any ALB listener rule (see SAFETY REVERT below).
2. ALB target events (identified structurally by requestContext.elb):
   branches on the Host header the ALB routed on.
     - Host == wake.<child_zone>: the fleet control page (list + start any
       service). START-ONLY by construction -- see _handle_wake_host, which
       is the single enforcement point that rejects any attempt to express a
       stop over HTTP.
     - Host == <svc>.<child_zone>: auto-wake (DORMANT -- see
       _handle_app_host). No code path flips a listener rule to the scaler
       anymore, so an app's own rule is never repointed here and this
       handler is currently unreachable in production.

SAFETY REVERT: stop paths used to also flip the targeted service's ALB
listener rule to this Lambda's own target group, so a stopped app's URL
would land on an auto-wake page instead of a dead 503. That flip is now
permanently removed: an ALB does not health-check a target group once it's
detached from a rule, so the app TG could never be observed "healthy" again
and the flip-back in _handle_app_host could never fire -- stopping an app
permanently stranded its URL behind an infinite warming loop. See
_stop_service and _handle_app_host for details.

boto3 comes from the Lambda Python 3.13 runtime; zero pip dependencies.
"""

import html
import json
import os
import re

import boto3

CLUSTER = os.environ["CLUSTER"]
APP_DOMAIN = os.environ["APP_DOMAIN"]
LISTENER_ARN = os.environ["LISTENER_ARN"]
SCALER_TG_ARN = os.environ["SCALER_TG_ARN"]

WAKE_HOST = f"wake.{APP_DOMAIN}"

ecs = boto3.client("ecs")
elbv2 = boto3.client("elbv2")


# ---------------------------------------------------------------------------
# ECS helpers
# ---------------------------------------------------------------------------


def _list_cluster_services():
    """Return {service_name: {"desired": int, "running": int}} for CLUSTER."""
    arns = []
    paginator = ecs.get_paginator("list_services")
    for page in paginator.paginate(cluster=CLUSTER):
        arns.extend(page.get("serviceArns", []))

    services = {}
    # describe_services accepts at most 10 services per call.
    for i in range(0, len(arns), 10):
        chunk = arns[i : i + 10]
        resp = ecs.describe_services(cluster=CLUSTER, services=chunk)
        for svc in resp.get("services", []):
            services[svc["serviceName"]] = {
                "desired": svc["desiredCount"],
                "running": svc["runningCount"],
            }
    return services


def _set_desired_count(name, count):
    print(json.dumps({"action": "update_service", "service": name, "desiredCount": count}))
    ecs.update_service(cluster=CLUSTER, service=name, desiredCount=count)


# ---------------------------------------------------------------------------
# ALB listener-rule helpers (the "rule flip"). Read-only Describe* calls have
# no resource-level IAM support so the scaler role holds them on "*";
# ModifyRule is scoped in Terraform to this ALB's own listener-rule ARN
# space (see scaler.tf) -- note that scope also technically covers this
# rule's own scaler listener rule (priority=1, host wake.<domain>), not just
# per-app rules. That's harmless (there's nothing sensitive to gain by
# repointing the scaler's own rule at itself) but it means the ModifyRule
# grant isn't per-app-isolated; flagging per review finding 6.
# ---------------------------------------------------------------------------


def _find_host_rule_arn(host):
    """Find the listener rule on LISTENER_ARN whose host-header condition is
    exactly [host]. DescribeRules returns every rule for one listener in a
    single call (no NextMarker/pagination token in this API) -- fleet-scale
    rule counts (one rule per app, realistically tens) sit nowhere near the
    per-listener rule ceiling AWS enforces, so no pagination loop is needed.
    """
    resp = elbv2.describe_rules(ListenerArn=LISTENER_ARN)
    for rule in resp.get("Rules", []):
        for cond in rule.get("Conditions", []):
            if cond.get("Field") != "host-header":
                continue
            values = cond.get("HostHeaderConfig", {}).get("Values") or cond.get("Values") or []
            if values == [host]:
                return rule["RuleArn"]
    return None


def _target_group_arn_by_name(name):
    resp = elbv2.describe_target_groups(Names=[name])
    tgs = resp.get("TargetGroups", [])
    if not tgs:
        raise LookupError(f"no target group named {name}")
    return tgs[0]["TargetGroupArn"]


def _target_group_healthy(tg_arn):
    resp = elbv2.describe_target_health(TargetGroupArn=tg_arn)
    return any(
        t.get("TargetHealth", {}).get("State") == "healthy"
        for t in resp.get("TargetHealthDescriptions", [])
    )


def _modify_rule_forward(rule_arn, target_group_arn):
    elbv2.modify_rule(
        RuleArn=rule_arn,
        Actions=[{"Type": "forward", "TargetGroupArn": target_group_arn}],
    )


def _flip_to_scaler(svc):
    """Repoint svc's listener rule at this Lambda's own target group. Only
    ever called from the non-HTTP action path (D4 security invariant:
    flips toward the scaler never happen as a side effect of an HTTP
    request).
    """
    host = f"{svc}.{APP_DOMAIN}"
    rule_arn = _find_host_rule_arn(host)
    if rule_arn is None:
        raise LookupError(f"no listener rule found for host {host}")
    print(json.dumps({"action": "flip_rule", "service": svc, "target": "scaler"}))
    _modify_rule_forward(rule_arn, SCALER_TG_ARN)


def _flip_to_app(svc):
    """Repoint svc's listener rule at its own app target group. Only ever
    called from the auto-wake ALB path, and only after that target group has
    been confirmed healthy (D4 invariant: HTTP can only make things MORE
    available).
    """
    host = f"{svc}.{APP_DOMAIN}"
    rule_arn = _find_host_rule_arn(host)
    if rule_arn is None:
        raise LookupError(f"no listener rule found for host {host}")
    app_tg_arn = _target_group_arn_by_name(f"flightdeck-{svc}")
    print(json.dumps({"action": "flip_rule", "service": svc, "target": "app"}))
    _modify_rule_forward(rule_arn, app_tg_arn)


# ---------------------------------------------------------------------------
# Per-service operations used by the action-event path. Each wraps its ECS
# (and, for stop, ELB) calls in try/except so one bad service name in a
# batch can't abort the rest -- callers collect {name: "ok"/error-message}
# and return it verbatim in the response JSON.
# ---------------------------------------------------------------------------


def _stop_service(name):
    # SAFETY REVERT (deadlock fix): stop paths used to also flip the app's
    # listener rule to the scaler target group here. That flip is now
    # permanently disabled -- an ALB does not health-check a target group
    # once it's detached from a rule, so the app TG could never report
    # "healthy" again, and _handle_app_host's flip-back condition (app TG
    # healthy) could never become true. That stranded the app behind an
    # infinite warming-page loop with no way back except a manual rule fix.
    # Stopping now ONLY sets desired count to 0; no code path may flip a
    # rule toward the scaler anymore. See _handle_app_host for the dormant
    # auto-wake-on-direct-visit handler this leaves unreachable.
    try:
        _set_desired_count(name, 0)
        return "ok"
    except Exception as e:  # noqa: BLE001 -- must not abort the batch
        print(json.dumps({"error": "update_service failed", "service": name, "message": str(e)}))
        return f"error: {e}"


def _start_service(name):
    # start/start-all deliberately do NOT flip the rule back eagerly (D3):
    # the rule stays on the scaler until a visitor (or the app's own
    # deploy) completes the flip-back via the healthy auto-wake path.
    try:
        _set_desired_count(name, 1)
        return "ok"
    except Exception as e:  # noqa: BLE001 -- must not abort the batch
        print(json.dumps({"error": "update_service failed", "service": name, "message": str(e)}))
        return f"error: {e}"


# ---------------------------------------------------------------------------
# Scheduler / direct-invoke events: {"action": ..., "services": [...]}
# ---------------------------------------------------------------------------


def _handle_action_event(event):
    action = event.get("action")
    services = event.get("services")
    print(json.dumps({"event_type": "action", "action": action, "services": services}))

    if action in ("stop-all", "start-all"):
        cluster_services = _list_cluster_services()
        names = sorted(cluster_services)
        worker = _stop_service if action == "stop-all" else _start_service
        results = {name: worker(name) for name in names}
        return {"status": "ok", "action": action, "results": results}

    if action in ("start", "stop"):
        if not services:
            print(json.dumps({"error": f"action={action} requires a non-empty services list"}))
            return {"status": "error", "message": f"action={action} requires a services list"}
        worker = _stop_service if action == "stop" else _start_service
        results = {name: worker(name) for name in services}
        return {"status": "ok", "action": action, "results": results}

    print(json.dumps({"warning": "unknown action, no changes made", "event": event}))
    return {"status": "ignored", "reason": "unknown action"}


# ---------------------------------------------------------------------------
# ALB target events
# ---------------------------------------------------------------------------

_PAGE_STYLE = """
    :root { color-scheme: light dark; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      max-width: 40rem;
      margin: 3rem auto;
      padding: 0 1.5rem;
      line-height: 1.5;
      background: #fff;
      color: #111;
    }
    @media (prefers-color-scheme: dark) {
      body { background: #111; color: #eee; }
    }
    code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
    table { border-collapse: collapse; width: 100%; margin-top: 1rem; }
    th, td { text-align: left; padding: 0.4rem 0.6rem; border-bottom: 1px solid #88888844; }
    a { color: inherit; }
    h1 { font-size: 1.3rem; }
    .summary { color: #555; }
    @media (prefers-color-scheme: dark) {
      .summary { color: #aaa; }
    }
    .state {
      display: inline-block;
      padding: 0.15rem 0.55rem;
      border-radius: 0.3rem;
      font-size: 0.85rem;
      color: #fff;
    }
    .state-running { background: #1a7f37; }
    .state-warming { background: #9a6700; }
    .state-asleep { background: #6e7781; }
    @media (prefers-color-scheme: dark) {
      .state-running { background: #2ea043; }
      .state-warming { background: #bb8009; }
      .state-asleep { background: #57606a; }
    }
"""


def _page(title, body_html, extra_head=""):
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title}</title>
<style>{_PAGE_STYLE}</style>
{extra_head}
</head>
<body>
{body_html}
</body>
</html>"""


def _html_response(body, status=200):
    return {
        "statusCode": status,
        "headers": {"Content-Type": "text/html; charset=utf-8"},
        "body": body,
        "isBase64Encoded": False,
    }


def _derive_service_state(name, info):
    """Best-effort status label for one service on the index page: "asleep"
    (desired==0), "running" (desired>=1 and the app's own target group has a
    healthy target), or "warming" (desired>=1, not yet healthy).

    Never raises -- this is a read-only fleet overview, so one service's
    missing/misnamed target group must not take the whole page down. If the
    TG lookup or health check fails, degrade to a counts-only guess (running
    tasks present -> "running", otherwise "warming") rather than erroring.
    """
    desired = info["desired"]
    running = info["running"]
    if desired == 0:
        return "asleep"
    try:
        tg_arn = _target_group_arn_by_name(f"flightdeck-{name}")
        healthy = _target_group_healthy(tg_arn)
    except Exception as e:  # noqa: BLE001 -- degrade to counts-only, never error the page
        print(json.dumps({"warning": "index target-health lookup failed", "service": name, "error": str(e)}))
        return "running" if running > 0 else "warming"
    return "running" if healthy else "warming"


def _index_response():
    services = _list_cluster_services()
    esc_domain = html.escape(APP_DOMAIN)
    total_desired = sum(info["desired"] for info in services.values())
    total_running = sum(info["running"] for info in services.values())
    state_counts = {"running": 0, "warming": 0, "asleep": 0}

    if services:
        rows = []
        for name, info in sorted(services.items()):
            state = _derive_service_state(name, info)
            state_counts[state] = state_counts.get(state, 0) + 1
            esc_name = html.escape(name)
            url = f"https://{esc_name}.{esc_domain}/"
            if state == "asleep":
                action = f'<a href="?svc={esc_name}">wake</a>'
            else:
                action = f'<a href="{url}">open</a>'
            rows.append(
                f"<tr>"
                f'<td><a href="{url}">{esc_name}</a></td>'
                f'<td><span class="state state-{state}">{state}</span></td>'
                f"<td>{info['desired']}</td><td>{info['running']}</td>"
                f"<td>{action}</td>"
                f"</tr>"
            )
        rows_html = "\n".join(rows)
    else:
        rows_html = '<tr><td colspan="5">No services registered on this cluster.</td></tr>'

    summary = (
        f"{len(services)} service(s) &middot; "
        f'{state_counts["running"]} running &middot; '
        f'{state_counts["warming"]} warming &middot; '
        f'{state_counts["asleep"]} asleep &middot; '
        f"{total_desired} desired / {total_running} running task(s)"
    )

    body = f"""
<h1>flightdeck services</h1>
<p>This endpoint scales stopped apps back up on demand. Apps also wake
automatically when visited directly at their own <code>&lt;svc&gt;.{esc_domain}</code>
URL -- this page is a quick look at the whole fleet.</p>
<p class="summary">{summary}</p>
<table>
<tr><th>service</th><th>state</th><th>desired</th><th>running</th><th></th></tr>
{rows_html}
</table>
"""
    return _html_response(_page("flightdeck: fleet status", body))


def _wake_all_response():
    services = _list_cluster_services()
    woken = [name for name, info in services.items() if info["desired"] == 0]
    for name in woken:
        _set_desired_count(name, 1)

    body = f"""
<h1>Waking all services</h1>
<p>{len(woken)} of {len(services)} service(s) were stopped and are now starting.
Usually ready in about a minute.</p>
<p><a href="?">Back to fleet status</a></p>
"""
    return _html_response(_page("flightdeck: waking all", body))


def _wake_response(svc):
    services = _list_cluster_services()
    if svc not in services:
        body = f"""
<h1>No such service</h1>
<p><code>{html.escape(svc)}</code> is not registered on this cluster.</p>
<p><a href="?">Back to fleet status</a></p>
"""
        return _html_response(_page("flightdeck: not found", body), status=404)

    info = services[svc]
    if info["desired"] == 0:
        _set_desired_count(svc, 1)
        status_line = "was stopped and is starting now. Usually ready in about a minute."
    else:
        status_line = "is already running."

    url = f"https://{html.escape(svc)}.{APP_DOMAIN}/"
    extra_head = f'<meta http-equiv="refresh" content="20;url={url}">'
    body = f"""
<h1>{html.escape(svc)}</h1>
<p>{html.escape(svc)} {status_line}</p>
<p>You'll be redirected to <a href="{url}">{url}</a> shortly.</p>
"""
    return _html_response(_page(f"flightdeck: waking {html.escape(svc)}", body, extra_head))


def _handle_wake_host(event):
    """https://wake.<child_zone>/ -- unchanged fleet index / ?svc= start
    endpoint. START-ONLY by construction: this is the single enforcement
    point that rejects any attempt to express a stop over HTTP.
    """
    query = event.get("queryStringParameters") or {}
    print(json.dumps({"event_type": "alb_wake_host", "path": event.get("path"), "query": query}))

    # Single enforcement point: this endpoint is START-ONLY. Any query
    # parameter other than the sanctioned "svc" (in particular an "action"
    # param, which would let someone try to puppet the same stop/start-all
    # verbs the scheduler uses) is rejected outright rather than inspected
    # for intent -- stopping happens via the nightly schedule or `make stop`,
    # never over HTTP.
    if "action" in query:
        return _html_response(
            "400 Bad Request: this endpoint only starts services. "
            "Stopping happens via the nightly schedule or `make stop`.",
            status=400,
        )

    svc = query.get("svc")
    if not svc:
        return _index_response()
    if svc == "all":
        return _wake_all_response()
    return _wake_response(svc)


def _warming_page(svc, url, refresh_seconds, healthy=False):
    esc_svc = html.escape(svc)
    esc_url = html.escape(url)
    extra_head = f'<meta http-equiv="refresh" content="{refresh_seconds};url={esc_url}">'
    if healthy:
        status_line = "is up. Taking you there now."
    else:
        status_line = "is starting up. This usually takes about a minute."
    body = f"""
<h1>{esc_svc}</h1>
<p>{esc_svc} {status_line}</p>
<p>This page refreshes automatically. If it doesn't,
<a href="{esc_url}">click here</a>.</p>
"""
    return _html_response(_page(f"flightdeck: waking {esc_svc}", body, extra_head))


def _not_found_page(svc):
    body = f"""
<h1>No such service</h1>
<p><code>{html.escape(svc)}</code> is not registered on this cluster.</p>
"""
    return _html_response(_page("flightdeck: not found", body), status=404)


def _handle_app_host(host):
    """https://<svc>.<child_zone>/ -- auto-wake. A request only reaches here
    because either the rule was flipped to this Lambda (by a stop) or the
    app never had healthy targets yet. START-ONLY and flip-TOWARD-app-only
    (D4): the query string is never even inspected on this path, so no
    query parameter of any kind can stop or flip-to-scaler anything here.

    DORMANT / SHELVED: auto-wake-on-direct-visit is disabled -- the stop
    path no longer flips rules to the scaler, so this handler is currently
    unreachable. It deadlocks as written (ALB does not health-check a
    detached target group); see the flightdeck GitHub issue on auto-wake
    before re-enabling. Kept for reference/reuse by the proper fix (Lambda
    VPC health probe, or flip-on-ECS-running with a fast TG health check).
    """
    # svc is the first DNS label of a Host the ALB itself matched against a
    # literal host-header condition before ever invoking this Lambda -- the
    # ALB only forwards to this target group for hosts an existing listener
    # rule condition names exactly, so this string is bounded by whatever
    # app names Terraform created rules for (design risk 4). Still validated
    # and html.escape'd defensively rather than trusted outright.
    svc = host[: -(len(APP_DOMAIN) + 1)]
    print(json.dumps({"event_type": "alb_app_host", "host": host, "svc": svc}))

    if not re.match(r"^[a-z0-9-]{1,32}$", svc):
        return _not_found_page(svc)

    services = _list_cluster_services()
    if svc not in services:
        return _not_found_page(svc)

    url = f"https://{svc}.{APP_DOMAIN}/"
    info = services[svc]

    if info["desired"] == 0:
        try:
            _set_desired_count(svc, 1)
        except Exception as e:  # noqa: BLE001 -- still serve the warming page
            print(json.dumps({"error": "auto-wake update_service failed", "service": svc, "message": str(e)}))
        return _warming_page(svc, url, refresh_seconds=15)

    # desired >= 1 already: check whether the app's own target group has a
    # healthy target yet before deciding whether to flip the rule back.
    try:
        app_tg_arn = _target_group_arn_by_name(f"flightdeck-{svc}")
        healthy = _target_group_healthy(app_tg_arn)
    except Exception as e:  # noqa: BLE001
        print(json.dumps({"error": "target-health check failed", "service": svc, "message": str(e)}))
        healthy = False

    if not healthy:
        return _warming_page(svc, url, refresh_seconds=15)

    # Healthy: flip the rule back to the app TG. CHANGE 2 (review): this
    # does NOT respond with an immediate 302. ALB rule updates propagate
    # asynchronously, so an instant redirect can race the propagation --
    # the re-request lands back on this Lambda, sees "healthy" again, and
    # 302s again -> ERR_TOO_MANY_REDIRECTS. A short (2s) meta-refresh to the
    # SAME url gives propagation a head start while still self-healing in
    # one more page load rather than an instant bounce.
    try:
        _flip_to_app(svc)
    except Exception as e:  # noqa: BLE001 -- still serve the page; next
        # visitor (or a deploy) retries the flip.
        print(json.dumps({"error": "flip-to-app failed", "service": svc, "message": str(e)}))
    return _warming_page(svc, url, refresh_seconds=2, healthy=True)


def _get_host(event):
    headers = event.get("headers") or {}
    host = headers.get("host") or headers.get("Host")
    if not host:
        mv_headers = event.get("multiValueHeaders") or {}
        values = mv_headers.get("host") or mv_headers.get("Host") or []
        host = values[0] if values else ""
    return host.split(":", 1)[0].lower()


def _handle_alb_event(event):
    host = _get_host(event)

    if host == WAKE_HOST:
        return _handle_wake_host(event)

    if host.endswith(f".{APP_DOMAIN}"):
        return _handle_app_host(host)

    # Shouldn't happen in practice: the ALB only routes wake.<domain> and
    # <svc>.<domain> hosts to this Lambda's target group at all (that's what
    # the listener rule conditions enforce) -- any other host hits the
    # listener's own default 404 fixed-response before ever reaching here.
    # Defensive fallback rather than trusting Host blindly.
    print(json.dumps({"warning": "unrecognized host reached the scaler Lambda", "host": host}))
    return _html_response("404 Not Found", status=404)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def lambda_handler(event, context):
    request_context = event.get("requestContext")
    if isinstance(request_context, dict) and "elb" in request_context:
        return _handle_alb_event(event)

    if "action" in event:
        return _handle_action_event(event)

    print(json.dumps({"warning": "unrecognized event shape, no action taken", "event": event}))
    return {"status": "ignored", "reason": "unrecognized event shape"}
