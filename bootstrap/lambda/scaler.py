"""flightdeck-scaler: nightly cool-down + ALB wake endpoint.

Two entrypoints share this one function (spec 5b: net-new, flightdeck-
prefixed, no speculative surface area):

1. Scheduler / direct-invoke events: {"action": ..., "services": [...]}.
   Drives ECS desired_count for the flightdeck cluster. Used by the nightly
   EventBridge Scheduler rule (action=stop-all) and available for manual
   invokes.
2. ALB target events (identified structurally by requestContext.elb):
   a small HTML control surface reachable at https://wake.<child_zone>/.
   This path is START-ONLY by construction -- see _handle_alb_event, which
   is the single enforcement point that rejects any attempt to express a
   stop over HTTP.

boto3 comes from the Lambda Python 3.13 runtime; zero pip dependencies.
"""

import html
import json
import os

import boto3

CLUSTER = os.environ["CLUSTER"]
APP_DOMAIN = os.environ["APP_DOMAIN"]

ecs = boto3.client("ecs")


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
# Scheduler / direct-invoke events: {"action": ..., "services": [...]}
# ---------------------------------------------------------------------------


def _handle_action_event(event):
    action = event.get("action")
    services = event.get("services")
    print(json.dumps({"event_type": "action", "action": action, "services": services}))

    if action in ("stop-all", "start-all"):
        desired = 0 if action == "stop-all" else 1
        cluster_services = _list_cluster_services()
        for name in cluster_services:
            _set_desired_count(name, desired)
        return {"status": "ok", "action": action, "services": sorted(cluster_services)}

    if action in ("start", "stop"):
        if not services:
            print(json.dumps({"error": f"action={action} requires a non-empty services list"}))
            return {"status": "error", "message": f"action={action} requires a services list"}
        desired = 1 if action == "start" else 0
        for name in services:
            _set_desired_count(name, desired)
        return {"status": "ok", "action": action, "services": services}

    print(json.dumps({"warning": "unknown action, no changes made", "event": event}))
    return {"status": "ignored", "reason": "unknown action"}


# ---------------------------------------------------------------------------
# ALB target events: wake.<child_zone>/?svc=<name>
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


def _index_response():
    services = _list_cluster_services()
    if services:
        rows = "\n".join(
            f"<tr><td>{name}</td><td>{info['desired']}</td><td>{info['running']}</td>"
            f'<td><a href="?svc={name}">wake</a></td></tr>'
            for name, info in sorted(services.items())
        )
    else:
        rows = '<tr><td colspan="4">No services registered on this cluster.</td></tr>'

    body = f"""
<h1>flightdeck fleet</h1>
<p>Services scale to zero overnight (deliberate cool-down). Wake one back up:</p>
<table>
<tr><th>service</th><th>desired</th><th>running</th><th></th></tr>
{rows}
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


def _handle_alb_event(event):
    query = event.get("queryStringParameters") or {}
    print(json.dumps({"event_type": "alb", "path": event.get("path"), "query": query}))

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
