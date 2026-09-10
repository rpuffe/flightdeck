import datetime
import importlib.util
import json
import os
import pathlib
import sys
import types
import unittest
from unittest.mock import MagicMock, call, patch


ROOT = pathlib.Path(__file__).resolve().parents[1]
SCALER_PATH = ROOT / "bootstrap" / "lambda" / "scaler.py"

os.environ.setdefault("CLUSTER", "flightdeck")
os.environ.setdefault("APP_DOMAIN", "fd.example.com")
os.environ.setdefault("IDLE_SLEEP_MINUTES", "30")

_clients = {"ecs": MagicMock(), "elbv2": MagicMock(), "cloudwatch": MagicMock()}
sys.modules.setdefault(
    "boto3",
    types.SimpleNamespace(client=lambda service: _clients[service]),
)

spec = importlib.util.spec_from_file_location("flightdeck_scaler", SCALER_PATH)
scaler = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scaler)


class FakePaginator:
    def __init__(self, pages):
        self.pages = pages

    def paginate(self, **kwargs):
        self.kwargs = kwargs
        return self.pages


class ScalerTests(unittest.TestCase):
    def setUp(self):
        scaler.ecs = MagicMock()
        scaler.elbv2 = MagicMock()
        scaler.cloudwatch = MagicMock()

    def test_lists_and_describes_services_in_ten_item_chunks(self):
        arns = [f"arn:aws:ecs:region:account:service/flightdeck/app-{index}" for index in range(12)]
        paginator = FakePaginator([{"serviceArns": arns[:7]}, {"serviceArns": arns[7:]}])
        scaler.ecs.get_paginator.return_value = paginator

        def describe_services(*, cluster, services):
            return {
                "services": [
                    {
                        "serviceName": arn.rsplit("/", 1)[-1],
                        "desiredCount": 1,
                        "runningCount": 1,
                    }
                    for arn in services
                ]
            }

        scaler.ecs.describe_services.side_effect = describe_services

        services = scaler._list_cluster_services()

        self.assertEqual(12, len(services))
        self.assertEqual({"cluster": "flightdeck"}, paginator.kwargs)
        self.assertEqual(2, scaler.ecs.describe_services.call_count)
        self.assertEqual(10, len(scaler.ecs.describe_services.call_args_list[0].kwargs["services"]))
        self.assertEqual(2, len(scaler.ecs.describe_services.call_args_list[1].kwargs["services"]))

    def test_stop_service_reports_success_and_failure(self):
        self.assertEqual("ok", scaler._stop_service("good"))
        scaler.ecs.update_service.assert_called_once_with(
            cluster="flightdeck", service="good", desiredCount=0
        )

        scaler.ecs.update_service.side_effect = RuntimeError("denied")
        self.assertEqual("error: denied", scaler._stop_service("bad"))

    def test_action_event_returns_error_when_any_service_fails(self):
        with (
            patch.object(scaler, "_start_service", side_effect=["ok", "error: denied"]),
            patch("builtins.print") as log,
        ):
            response = scaler._handle_action_event(
                {"action": "start", "services": ["good", "bad"]}
            )

        self.assertEqual("error", response["status"])
        self.assertEqual({"good": "ok", "bad": "error: denied"}, response["results"])
        result_log = json.loads(log.call_args_list[-1].args[0])
        self.assertEqual("action_result", result_log["event_type"])
        self.assertEqual("error", result_log["status"])
        self.assertEqual(response["results"], result_log["results"])

    def test_action_event_validates_shape(self):
        missing = scaler._handle_action_event({"action": "stop"})
        unknown = scaler._handle_action_event({"action": "destroy-all"})

        self.assertEqual("error", missing["status"])
        self.assertEqual("ignored", unknown["status"])

    def test_stop_all_sorts_services_before_processing(self):
        with (
            patch.object(
                scaler,
                "_list_cluster_services",
                return_value={"zeta": {}, "alpha": {}},
            ),
            patch.object(scaler, "_stop_service", return_value="ok") as stop,
        ):
            response = scaler._handle_action_event({"action": "stop-all"})

        self.assertEqual("ok", response["status"])
        self.assertEqual([call("alpha"), call("zeta")], stop.call_args_list)

    def test_index_escapes_service_names(self):
        with (
            patch.object(
                scaler,
                "_list_cluster_services",
                return_value={"<script>": {"desired": 0, "running": 0}},
            ),
            patch.object(scaler, "_derive_service_state", return_value="asleep"),
        ):
            response = scaler._index_response()

        self.assertEqual(200, response["statusCode"])
        self.assertNotIn("<script>", response["body"])
        self.assertIn("&lt;script&gt;", response["body"])

    def test_unknown_wake_service_is_escaped(self):
        with patch.object(scaler, "_list_cluster_services", return_value={}):
            response = scaler._wake_response("<img src=x onerror=alert(1)>")

        self.assertEqual(404, response["statusCode"])
        self.assertNotIn("<img", response["body"])
        self.assertIn("&lt;img", response["body"])

    def test_wake_starts_sleeping_service_and_polls_until_healthy(self):
        with (
            patch.object(
                scaler,
                "_list_cluster_services",
                return_value={"demo": {"desired": 0, "running": 0}},
            ),
            patch.object(scaler, "_set_desired_count") as set_count,
            patch.object(scaler, "_target_group_arn_by_name", return_value="tg"),
            patch.object(scaler, "_target_group_healthy", return_value=False),
        ):
            response = scaler._wake_response("demo")

        set_count.assert_called_once_with("demo", 1)
        self.assertIn('content="6;url=?svc=demo"', response["body"])

    def test_wake_redirects_only_after_target_is_healthy(self):
        with (
            patch.object(
                scaler,
                "_list_cluster_services",
                return_value={"demo": {"desired": 1, "running": 1}},
            ),
            patch.object(scaler, "_target_group_arn_by_name", return_value="tg"),
            patch.object(scaler, "_target_group_healthy", return_value=True),
        ):
            response = scaler._wake_response("demo")

        self.assertIn("https://demo.fd.example.com/", response["body"])
        self.assertIn('content="1;url=https://demo.fd.example.com/"', response["body"])

    def test_public_endpoint_rejects_stop_actions(self):
        response = scaler._handle_wake_host(
            {"path": "/", "queryStringParameters": {"action": "stop-all"}}
        )

        self.assertEqual(400, response["statusCode"])
        self.assertIn("only starts services", response["body"])

    def test_alb_handler_accepts_only_wake_host(self):
        wake_event = {
            "headers": {"host": "wake.fd.example.com:443"},
            "queryStringParameters": None,
        }
        with patch.object(scaler, "_index_response", return_value={"statusCode": 200}):
            self.assertEqual(200, scaler._handle_alb_event(wake_event)["statusCode"])

        other_event = {"headers": {"Host": "demo.fd.example.com"}}
        self.assertEqual(404, scaler._handle_alb_event(other_event)["statusCode"])

    def test_lambda_handler_dispatches_supported_event_shapes(self):
        with patch.object(scaler, "_handle_alb_event", return_value={"statusCode": 200}) as alb:
            response = scaler.lambda_handler({"requestContext": {"elb": {}}}, None)
            self.assertEqual(200, response["statusCode"])
            alb.assert_called_once()

        with patch.object(scaler, "_handle_action_event", return_value={"status": "ok"}) as action:
            response = scaler.lambda_handler({"action": "start-all"}, None)
            self.assertEqual("ok", response["status"])
            action.assert_called_once()

        self.assertEqual(
            "ignored", scaler.lambda_handler({"unexpected": True}, None)["status"]
        )

    def test_sleep_idle_stops_only_the_truly_idle_service(self):
        now = datetime.datetime(2024, 1, 1, 12, 0, 0, tzinfo=datetime.timezone.utc)
        dims = {
            "active": ("targetgroup/flightdeck-active/1", "app/flightdeck/1"),
            "idle": ("targetgroup/flightdeck-idle/1", "app/flightdeck/1"),
            "no-tasks": ("targetgroup/flightdeck-no-tasks/1", "app/flightdeck/1"),
            "warm": ("targetgroup/flightdeck-warm/1", "app/flightdeck/1"),
        }
        newest_by_name = {
            "idle": now - datetime.timedelta(minutes=60),
            "no-tasks": None,
            "warm": now - datetime.timedelta(minutes=5),
        }

        with (
            patch.object(
                scaler,
                "_list_cluster_services",
                return_value={
                    name: {"desired": 1}
                    for name in ("active", "idle", "no-target-group", "no-tasks", "warm")
                },
            ),
            patch.object(scaler, "_target_groups_by_service", return_value=dims) as tgs,
            patch.object(
                scaler,
                "_request_counts",
                return_value={"active": 5, "idle": 0, "no-tasks": 0, "warm": 0},
            ),
            patch.object(
                scaler,
                "_newest_task_created_at",
                side_effect=lambda name: newest_by_name[name],
            ),
            patch.object(scaler, "_stop_service", return_value="ok") as stop,
            patch("builtins.print") as log,
        ):
            response = scaler._handle_sleep_idle(now=now)

        tgs.assert_called_once_with(["active", "idle", "no-target-group", "no-tasks", "warm"])
        self.assertEqual(
            {
                "active": "active",
                "idle": "ok",
                "no-target-group": "no-target-group",
                "no-tasks": "no-tasks",
                "warm": "warm",
            },
            response["results"],
        )
        stop.assert_called_once_with("idle")
        result_log = json.loads(log.call_args_list[-1].args[0])
        self.assertEqual("action_result", result_log["event_type"])
        self.assertEqual("sleep-idle", result_log["action"])

    def test_sleep_idle_is_ignored_when_disabled(self):
        with (
            patch.object(scaler, "IDLE_SLEEP_MINUTES", 0),
            patch.object(scaler, "_list_cluster_services") as list_services,
        ):
            response = scaler._handle_sleep_idle()

        self.assertEqual("ignored", response["status"])
        list_services.assert_not_called()

    def test_action_event_dispatches_sleep_idle(self):
        with patch.object(
            scaler, "_handle_sleep_idle", return_value={"status": "ok"}
        ) as handler:
            response = scaler._handle_action_event({"action": "sleep-idle"})

        handler.assert_called_once_with()
        self.assertEqual({"status": "ok"}, response)

    def test_target_groups_by_service_maps_dimensions_and_skips_detached(self):
        scaler.elbv2.describe_target_groups.return_value = {
            "TargetGroups": [
                {
                    "TargetGroupName": "flightdeck-golf",
                    "TargetGroupArn": "arn:aws:elasticloadbalancing:us-east-1:123:targetgroup/flightdeck-golf/abc",
                    "LoadBalancerArns": [
                        "arn:aws:elasticloadbalancing:us-east-1:123:loadbalancer/app/flightdeck/def"
                    ],
                },
                {
                    "TargetGroupName": "flightdeck-detached",
                    "TargetGroupArn": "arn:aws:elasticloadbalancing:us-east-1:123:targetgroup/flightdeck-detached/xyz",
                    "LoadBalancerArns": [],
                },
            ]
        }

        result = scaler._target_groups_by_service(["golf", "detached"])

        self.assertEqual(
            {"golf": ("targetgroup/flightdeck-golf/abc", "app/flightdeck/def")}, result
        )

    def test_target_groups_by_service_falls_back_to_single_lookups(self):
        scaler.elbv2.describe_target_groups.side_effect = [
            RuntimeError("batch describe failed"),
            {
                "TargetGroups": [
                    {
                        "TargetGroupName": "flightdeck-a",
                        "TargetGroupArn": "arn:aws:elasticloadbalancing:us-east-1:123:targetgroup/flightdeck-a/1",
                        "LoadBalancerArns": [
                            "arn:aws:elasticloadbalancing:us-east-1:123:loadbalancer/app/flightdeck/1"
                        ],
                    }
                ]
            },
            RuntimeError("no such target group: b"),
        ]

        result = scaler._target_groups_by_service(["a", "b"])

        self.assertEqual({"a": ("targetgroup/flightdeck-a/1", "app/flightdeck/1")}, result)

    def test_request_counts_builds_one_query_per_service_and_sums_values(self):
        dims = {
            "golf": ("targetgroup/flightdeck-golf/abc", "app/flightdeck/def"),
            "beta": ("targetgroup/flightdeck-beta/xyz", "app/flightdeck/def"),
        }
        start = datetime.datetime(2024, 1, 1, 11, 50, tzinfo=datetime.timezone.utc)
        end = datetime.datetime(2024, 1, 1, 12, 0, tzinfo=datetime.timezone.utc)
        scaler.cloudwatch.get_metric_data.return_value = {
            "MetricDataResults": [
                {"Id": "q0", "Values": [3, 4]},
                {"Id": "q1"},
            ]
        }

        result = scaler._request_counts(dims, start, end)

        self.assertEqual({"beta": 7, "golf": 0}, result)
        queries = scaler.cloudwatch.get_metric_data.call_args.kwargs["MetricDataQueries"]
        self.assertEqual(2, len(queries))
        for query in queries:
            metric = query["MetricStat"]
            self.assertEqual("AWS/ApplicationELB", metric["Metric"]["Namespace"])
            self.assertEqual("RequestCount", metric["Metric"]["MetricName"])
            self.assertEqual("Sum", metric["Stat"])
            self.assertGreaterEqual(metric["Period"], 60)
            self.assertEqual(0, metric["Period"] % 60)

    def test_index_response_mentions_idle_note_only_when_enabled(self):
        with (
            patch.object(scaler, "_list_cluster_services", return_value={}),
            patch.object(scaler, "IDLE_SLEEP_MINUTES", 30),
        ):
            enabled = scaler._index_response()
        self.assertIn("go back to sleep", enabled["body"])

        with (
            patch.object(scaler, "_list_cluster_services", return_value={}),
            patch.object(scaler, "IDLE_SLEEP_MINUTES", 0),
        ):
            disabled = scaler._index_response()
        self.assertNotIn("go back to sleep", disabled["body"])


if __name__ == "__main__":
    unittest.main()
