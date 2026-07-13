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

_clients = {"ecs": MagicMock(), "elbv2": MagicMock()}
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


if __name__ == "__main__":
    unittest.main()
