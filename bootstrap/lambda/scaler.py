"""flightdeck-scaler: idle sleep, nightly cool-down, optional morning
warm-up, and the explicit ALB wake endpoint.

Two entrypoints share this one function:

1. Scheduler / direct-invoke events: {"action": ..., "services": [...]}.
   Drives ECS desired_count for the flightdeck cluster. Used by the
   EventBridge Scheduler rules (action=sleep-idle every few minutes, nightly
   action=stop-all, optional morning action=start over a scoped service
   list), `make stop`/`make start`/`make stop-all`/`make start-all`, and any
   other direct invoke. Stop actions only set desired_count to 0.
2. ALB target events (identified structurally by requestContext.elb):
   serve only wake.<child_zone>. The public endpoint lists fleet state and
   starts a selected service. It is start-only by construction; stopping is
   available only through the schedules or authenticated direct invocation.

boto3 comes from the Lambda Python 3.13 runtime; zero pip dependencies.
"""

import datetime
import html
import json
import os

import boto3

CLUSTER = os.environ["CLUSTER"]
APP_DOMAIN = os.environ["APP_DOMAIN"]
IDLE_SLEEP_MINUTES = int(os.environ.get("IDLE_SLEEP_MINUTES", "0"))

WAKE_HOST = f"wake.{APP_DOMAIN}"

ecs = boto3.client("ecs")
elbv2 = boto3.client("elbv2")
cloudwatch = boto3.client("cloudwatch")


def _list_cluster_services():
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


def _stop_service(name):
    try:
        _set_desired_count(name, 0)
        return "ok"
    except Exception as e:  # noqa: BLE001 -- must not abort the batch
        print(json.dumps({"error": "update_service failed", "service": name, "message": str(e)}))
        return f"error: {e}"


def _start_service(name):
    try:
        _set_desired_count(name, 1)
        return "ok"
    except Exception as e:  # noqa: BLE001 -- must not abort the batch
        print(json.dumps({"error": "update_service failed", "service": name, "message": str(e)}))
        return f"error: {e}"


# ALB metrics exclude health-check requests, so RequestCount on a service's
# own target group counts only real client traffic.


def _target_groups_by_service(names):
    found = {}
    # describe_target_groups accepts at most 20 names per call, and fails the
    # whole call if any name is unknown -- so resolve one name at a time on
    # that error path rather than losing the batch.
    for i in range(0, len(names), 20):
        chunk = names[i : i + 20]
        try:
            tgs = elbv2.describe_target_groups(Names=[f"flightdeck-{n}" for n in chunk])["TargetGroups"]
        except Exception as e:  # noqa: BLE001 -- one unknown TG must not blank the batch
            print(json.dumps({"warning": "describe_target_groups batch failed, resolving singly", "error": str(e)}))
            tgs = []
            for n in chunk:
                try:
                    tgs.extend(elbv2.describe_target_groups(Names=[f"flightdeck-{n}"])["TargetGroups"])
                except Exception as single:  # noqa: BLE001
                    print(json.dumps({"warning": "no target group for service", "service": n, "error": str(single)}))
        for tg in tgs:
            name = tg["TargetGroupName"].removeprefix("flightdeck-")
            lbs = tg.get("LoadBalancerArns") or []
            if not lbs:
                continue
            # arn:...:targetgroup/<name>/<id> -> targetgroup/<name>/<id>
            tg_suffix = tg["TargetGroupArn"].split(":")[-1]
            # arn:...:loadbalancer/app/<name>/<id> -> app/<name>/<id>
            lb_suffix = lbs[0].split(":loadbalancer/", 1)[-1]
            found[name] = (tg_suffix, lb_suffix)
    return found


def _request_counts(dimensions_by_service, start, end):
    if not dimensions_by_service:
        return {}
    period = max(60, int((end - start).total_seconds()) // 60 * 60)
    ordered = sorted(dimensions_by_service)
    queries = [
        {
            "Id": f"q{i}",
            "MetricStat": {
                "Metric": {
                    "Namespace": "AWS/ApplicationELB",
                    "MetricName": "RequestCount",
                    "Dimensions": [
                        {"Name": "TargetGroup", "Value": dimensions_by_service[name][0]},
                        {"Name": "LoadBalancer", "Value": dimensions_by_service[name][1]},
                    ],
                },
                "Period": period,
                "Stat": "Sum",
            },
        }
        for i, name in enumerate(ordered)
    ]
    counts = {name: 0.0 for name in ordered}
    resp = cloudwatch.get_metric_data(MetricDataQueries=queries, StartTime=start, EndTime=end)
    for result in resp.get("MetricDataResults", []):
        name = ordered[int(result["Id"][1:])]
        counts[name] = sum(result.get("Values") or [])
    return counts


def _newest_task_created_at(name):
    arns = ecs.list_tasks(cluster=CLUSTER, serviceName=name).get("taskArns") or []
    if not arns:
        return None
    tasks = ecs.describe_tasks(cluster=CLUSTER, tasks=arns[:100]).get("tasks") or []
    stamps = [t["createdAt"] for t in tasks if t.get("createdAt")]
    return max(stamps) if stamps else None


def _handle_sleep_idle(now=None):
    if IDLE_SLEEP_MINUTES <= 0:
        print(json.dumps({"warning": "sleep-idle invoked while disabled (IDLE_SLEEP_MINUTES=0)"}))
        return {"status": "ignored", "reason": "sleep-idle disabled"}

    now = now or datetime.datetime.now(datetime.timezone.utc)
    window_start = now - datetime.timedelta(minutes=IDLE_SLEEP_MINUTES)

    try:
        services = _list_cluster_services()
        candidates = sorted(name for name, info in services.items() if info["desired"] > 0)
        dims = _target_groups_by_service(candidates)
        counts = _request_counts(dims, window_start, now)
    except Exception as e:  # noqa: BLE001 -- degrade to "no changes", never a silent crash
        response = {"status": "error", "action": "sleep-idle", "message": f"fleet lookup failed: {e}"}
        print(json.dumps({"event_type": "action_result", **response}))
        return response

    results = {}

    for name in candidates:
        try:
            if name not in dims:
                results[name] = "no-target-group"
                continue
            if counts.get(name, 0) > 0:
                results[name] = "active"
                continue
            newest = _newest_task_created_at(name)
            if newest is None:
                results[name] = "no-tasks"
                continue
            if newest > window_start:
                results[name] = "warm"
                continue
            results[name] = _stop_service(name)
        except Exception as e:  # noqa: BLE001 -- one service must not abort the sweep
            print(json.dumps({"error": "sleep-idle check failed", "service": name, "message": str(e)}))
            results[name] = f"error: {e}"

    status = "ok" if not any(r.startswith("error") for r in results.values()) else "error"
    response = {
        "status": status,
        "action": "sleep-idle",
        "idle_minutes": IDLE_SLEEP_MINUTES,
        "results": results,
        "requests": {name: counts.get(name, 0) for name in candidates},
    }
    print(json.dumps({"event_type": "action_result", **response}))
    return response


def _handle_action_event(event):
    action = event.get("action")
    services = event.get("services")
    print(json.dumps({"event_type": "action", "action": action, "services": services}))

    if action == "sleep-idle":
        return _handle_sleep_idle()

    if action in ("stop-all", "start-all"):
        cluster_services = _list_cluster_services()
        names = sorted(cluster_services)
        worker = _stop_service if action == "stop-all" else _start_service
        results = {name: worker(name) for name in names}
        status = "ok" if all(result == "ok" for result in results.values()) else "error"
        response = {"status": status, "action": action, "results": results}
        print(json.dumps({"event_type": "action_result", **response}))
        return response

    if action in ("start", "stop"):
        if not services:
            print(json.dumps({"error": f"action={action} requires a non-empty services list"}))
            return {"status": "error", "message": f"action={action} requires a services list"}
        worker = _stop_service if action == "stop" else _start_service
        results = {name: worker(name) for name in services}
        status = "ok" if all(result == "ok" for result in results.values()) else "error"
        response = {"status": status, "action": action, "results": results}
        print(json.dumps({"event_type": "action_result", **response}))
        return response

    print(json.dumps({"warning": "unknown action, no changes made", "event": event}))
    return {"status": "ignored", "reason": "unknown action"}


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
            wake_url = f"?svc={esc_name}"
            if state == "running":
                name_link = url
                action = f'<a href="{url}">open</a>'
            else:
                name_link = wake_url
                action = f'<a href="{wake_url}">wake</a>'
            rows.append(
                f"<tr>"
                f'<td><a href="{name_link}">{esc_name}</a></td>'
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
    idle_note = (
        f"<p>Apps go back to sleep on their own after {IDLE_SLEEP_MINUTES} minutes "
        f"without requests, so wake what you want to look at and it'll tidy itself up.</p>"
        if IDLE_SLEEP_MINUTES > 0
        else ""
    )

    body = f"""
<h1>flightdeck services</h1>
<p>This page shows the fleet. A stopped app's row has a "wake" link that
starts it and waits until it's ready. Visiting a stopped app directly at
its own <code>&lt;svc&gt;.{esc_domain}</code> URL currently returns a 503 --
auto-wake on direct visit is temporarily disabled.</p>
{idle_note}
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

    try:
        tg_arn = _target_group_arn_by_name(f"flightdeck-{svc}")
        healthy = _target_group_healthy(tg_arn)
    except Exception as e:  # noqa: BLE001 -- degrade to warming/poll, never 500 the page
        print(json.dumps({"warning": "wake target-health check failed", "service": svc, "error": str(e)}))
        healthy = False

    if healthy:
        url = f"https://{svc}.{APP_DOMAIN}/"
        return _warming_page(svc, url, refresh_seconds=1, healthy=True)

    poll_url = f"?svc={svc}"
    return _warming_page(svc, poll_url, refresh_seconds=6, healthy=False)


def _handle_wake_host(event):
    query = event.get("queryStringParameters") or {}
    print(json.dumps({"event_type": "alb_wake_host", "path": event.get("path"), "query": query}))

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

    print(json.dumps({"warning": "unrecognized host reached the scaler Lambda", "host": host}))
    return _html_response("404 Not Found", status=404)


def lambda_handler(event, context):
    request_context = event.get("requestContext")
    if isinstance(request_context, dict) and "elb" in request_context:
        return _handle_alb_event(event)

    if "action" in event:
        return _handle_action_event(event)

    print(json.dumps({"warning": "unrecognized event shape, no action taken", "event": event}))
    return {"status": "ignored", "reason": "unrecognized event shape"}
