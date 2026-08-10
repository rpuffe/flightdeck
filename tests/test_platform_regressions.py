from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]


class StudioDeployRegressionTests(unittest.TestCase):
    def test_deploy_role_can_manage_log_metric_filters(self):
        oidc = (ROOT / "bootstrap" / "oidc.tf").read_text()
        log_groups_start = oidc.index('sid = "LogGroups"')
        log_groups_end = oidc.index("\n  statement {", log_groups_start)
        log_groups_statement = oidc[log_groups_start:log_groups_end]

        for action in (
            '"logs:PutMetricFilter"',
            '"logs:DescribeMetricFilters"',
            '"logs:DeleteMetricFilter"',
        ):
            self.assertIn(action, log_groups_statement)

        self.assertIn(
            '"arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:${local.name_prefix}/${service}"',
            log_groups_statement,
        )
        resources_start = log_groups_statement.index("resources =")
        self.assertNotIn('"*"', log_groups_statement[resources_start:])

    def test_stateful_service_disables_availability_zone_rebalancing(self):
        module = (ROOT / "modules" / "fargate-service" / "main.tf").read_text()

        for setting in (
            'deployment_maximum_percent         = var.storage != "" ? 100 : 200',
            'deployment_minimum_healthy_percent = var.storage != "" ? 0 : 100',
            'availability_zone_rebalancing = var.storage != "" ? "DISABLED" : null',
        ):
            self.assertIn(setting, module)


if __name__ == "__main__":
    unittest.main()
