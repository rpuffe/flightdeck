import os
from pathlib import Path
import subprocess
import tempfile
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


class ManagedSecretsRegressionTests(unittest.TestCase):
    BASE_MANIFEST = """\
name: secret-test
port: 8080
healthcheck: /healthz
cpu: 256
memory: 512
"""

    def validate_manifest(self, suffix=""):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".yaml") as manifest:
            manifest.write(self.BASE_MANIFEST + suffix)
            manifest.flush()
            return subprocess.run(
                [
                    "make",
                    "-f",
                    str(ROOT / "template-app" / "Makefile"),
                    "validate-manifest",
                    f"MANIFEST={manifest.name}",
                ],
                cwd=ROOT,
                text=True,
                capture_output=True,
                check=False,
            )

    def test_manifest_accepts_omitted_and_valid_secret_names(self):
        self.assertEqual(self.validate_manifest().returncode, 0)
        result = self.validate_manifest("secrets:\n  - SIGNWELL_API_KEY\n  - SES_TOKEN\n")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_manifest_rejects_invalid_duplicate_reserved_and_env_overlap(self):
        invalid_cases = (
            "secrets:\n  - lowercase\n",
            "secrets:\n  - A" + "B" * 64 + "\n",
            "secrets:\n  - API_KEY\n  - API_KEY\n",
            "secrets:\n  - STORAGE_BUCKET\n",
            "env:\n  API_KEY: public\nsecrets:\n  - API_KEY\n",
            "secrets: API_KEY\n",
            "secrets:\n" + "".join(f"  - KEY_{i}\n" for i in range(21)),
        )
        for suffix in invalid_cases:
            with self.subTest(suffix=suffix):
                self.assertNotEqual(self.validate_manifest(suffix).returncode, 0)

    def test_task_definition_uses_ssm_arn_and_execution_role_only(self):
        module = (ROOT / "modules" / "fargate-service" / "main.tf").read_text()
        variables = (ROOT / "modules" / "fargate-service" / "variables.tf").read_text()

        self.assertIn('variable "secrets"', variables)
        self.assertIn(
            "parameter/flightdeck/${var.name}/${var.environment}/${name}",
            module,
        )
        self.assertIn('resource "aws_iam_role_policy_attachment" "exec_secrets"', module)
        self.assertIn("role       = aws_iam_role.exec.name", module)
        self.assertNotIn("role       = aws_iam_role.task.name\n  policy_arn = \"arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/flightdeck-${local.svc_name}-exec-secrets\"", module)
        self.assertIn("length(local.container_secrets) > 0 ?", module)

    def test_bootstrap_scopes_exec_policy_by_app_and_environment(self):
        oidc = (ROOT / "bootstrap" / "oidc.tf").read_text()

        self.assertIn('resource "aws_iam_policy" "exec_secrets"', oidc)
        self.assertIn(
            "parameter/${local.name_prefix}/${each.value.app}/${each.value.environment}/*",
            oidc,
        )
        self.assertIn(
            "role/${local.name_prefix}-${statement.value}-exec",
            oidc,
        )
        self.assertIn(
            "policy/${local.name_prefix}-${statement.value}-exec-secrets",
            oidc,
        )

    def run_secret_script(self, action, stdin):
        with tempfile.TemporaryDirectory() as temp_dir:
            temp = Path(temp_dir)
            manifest = temp / "app-manifest.yaml"
            manifest.write_text("name: secret-test\nsecrets:\n  - API_KEY\n")
            aws_log = temp / "aws.log"
            aws_value = temp / "aws.value"

            yq = temp / "yq"
            yq.write_text(
                "#!/bin/sh\n"
                "if [ \"$1\" = .name ]; then echo secret-test; exit 0; fi\n"
                "if [ \"$1\" = -e ]; then\n"
                "  case \"$2\" in\n"
                "    *'contains([\"API_KEY\"])'*) exit 0 ;;\n"
                "    *) echo unsupported-yq-expression >&2; exit 2 ;;\n"
                "  esac\n"
                "fi\n"
                "exit 2\n"
            )
            yq.chmod(0o755)

            aws = temp / "aws"
            aws.write_text(
                "#!/bin/sh\n"
                "printf '%s\\n' \"$*\" >>\"$TEST_AWS_LOG\"\n"
                "case \"$1 $2\" in\n"
                "  'sts get-caller-identity') echo 123456789012 ;;\n"
                "  'ssm put-parameter')\n"
                "    while [ \"$#\" -gt 0 ]; do\n"
                "      if [ \"$1\" = --value ]; then value_file=${2#file://}; fi\n"
                "      shift\n"
                "    done\n"
                "    cat \"$value_file\" >\"$TEST_AWS_VALUE\" ;;\n"
                "  *) echo ok ;;\n"
                "esac\n"
            )
            aws.chmod(0o755)

            env = os.environ.copy()
            env["PATH"] = f"{temp}:{env['PATH']}"
            env["TEST_AWS_LOG"] = str(aws_log)
            env["TEST_AWS_VALUE"] = str(aws_value)
            result = subprocess.run(
                [
                    str(ROOT / "scripts" / "secret.sh"),
                    action,
                    str(manifest),
                    "dev",
                    "API_KEY",
                    "us-east-1",
                ],
                input=stdin,
                text=True,
                capture_output=True,
                env=env,
                check=False,
            )
            return result, aws_log.read_text(), aws_value.read_text() if aws_value.exists() else ""

    def test_secret_set_keeps_value_out_of_process_arguments_and_output(self):
        secret = "not-for-logs value"
        result, aws_log, stored_value = self.run_secret_script("set", secret + "\n")

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(stored_value, secret)
        self.assertNotIn(secret, result.stdout + result.stderr + aws_log)
        self.assertIn("--region us-east-1", aws_log)
        self.assertNotIn("--overwrite", aws_log)
        value_argument = next(
            part for part in aws_log.split() if part.startswith("file://")
        )
        self.assertFalse(Path(value_argument.removeprefix("file://")).exists())

    def test_secret_rotate_overwrites_and_restarts_exact_dev_service(self):
        result, aws_log, _ = self.run_secret_script("rotate", "replacement\n")

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("--overwrite", aws_log)
        self.assertIn(
            "ecs update-service --region us-east-1 --cluster flightdeck --service secret-test-dev --force-new-deployment",
            aws_log,
        )

    def test_secret_delete_is_confirmation_gated_and_region_pinned(self):
        cancelled, cancelled_log, _ = self.run_secret_script("delete", "no\n")
        self.assertNotEqual(cancelled.returncode, 0)
        self.assertNotIn("ssm delete-parameter", cancelled_log)

        deleted, deleted_log, _ = self.run_secret_script("delete", "DELETE\n")
        self.assertEqual(deleted.returncode, 0, deleted.stdout + deleted.stderr)
        self.assertIn(
            "ssm delete-parameter --region us-east-1 --name /flightdeck/secret-test/dev/API_KEY",
            deleted_log,
        )


if __name__ == "__main__":
    unittest.main()
