"""Keep the per-app deploy role in step with modules/fargate-service.

The deploy role (bootstrap/oidc.tf) is the only identity that applies an app's
module, and a missing IAM action only shows up on the first real apply. Two
rules make that class of mistake fail here instead:

1. The module never declares IAM policies; policies are bootstrap-owned.
2. Every resource type the module declares is listed in DEPLOY_ROLE_ACTIONS
   with the actions the deploy role needs, and each action is granted by a
   deploy_*_permissions policy document in bootstrap/oidc.tf.
"""

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MODULE = ROOT / "modules" / "fargate-service"
OIDC = ROOT / "bootstrap" / "oidc.tf"

# IAM resources the module may declare. Everything else under aws_iam_* is
# refused: policies (managed, inline, attachments-by-policy) live in bootstrap.
ALLOWED_IAM_RESOURCES = {"aws_iam_role", "aws_iam_role_policy_attachment"}

# Single source of truth: module resource type -> actions the deploy role needs
# to create, read (refresh), update and destroy it.
DEPLOY_ROLE_ACTIONS = {
    "aws_cloudwatch_log_group": [
        "logs:CreateLogGroup", "logs:DeleteLogGroup", "logs:DescribeLogGroups",
        "logs:PutRetentionPolicy", "logs:TagResource", "logs:ListTagsForResource",
    ],
    "aws_cloudwatch_log_metric_filter": [
        "logs:PutMetricFilter", "logs:DeleteMetricFilter", "logs:DescribeMetricFilters",
    ],
    "aws_cloudwatch_metric_alarm": [
        "cloudwatch:PutMetricAlarm", "cloudwatch:DeleteAlarms", "cloudwatch:DescribeAlarms",
    ],
    "aws_cognito_user_pool": [
        "cognito-idp:CreateUserPool", "cognito-idp:UpdateUserPool",
        "cognito-idp:DeleteUserPool", "cognito-idp:DescribeUserPool",
        "cognito-idp:SetUserPoolMfaConfig", "cognito-idp:GetUserPoolMfaConfig",
        "cognito-idp:TagResource", "cognito-idp:ListTagsForResource",
    ],
    "aws_cognito_user_pool_client": [
        "cognito-idp:CreateUserPoolClient", "cognito-idp:UpdateUserPoolClient",
        "cognito-idp:DeleteUserPoolClient", "cognito-idp:DescribeUserPoolClient",
    ],
    "aws_cognito_user_pool_domain": [
        "cognito-idp:CreateUserPoolDomain", "cognito-idp:DeleteUserPoolDomain",
        "cognito-idp:DescribeUserPoolDomain",
    ],
    "aws_ecs_service": [
        "ecs:CreateService", "ecs:UpdateService", "ecs:DeleteService", "ecs:DescribeServices",
    ],
    "aws_ecs_task_definition": [
        "ecs:RegisterTaskDefinition", "ecs:DescribeTaskDefinition",
        "ecs:DeregisterTaskDefinition",
    ],
    "aws_iam_role": [
        "iam:CreateRole", "iam:GetRole", "iam:DeleteRole", "iam:TagRole", "iam:UntagRole",
        "iam:PutRolePermissionsBoundary", "iam:ListRolePolicies",
        "iam:ListAttachedRolePolicies", "iam:ListInstanceProfilesForRole",
    ],
    "aws_iam_role_policy_attachment": [
        "iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:ListAttachedRolePolicies",
    ],
    "aws_lb_listener_rule": [
        "elasticloadbalancing:CreateRule", "elasticloadbalancing:ModifyRule",
        "elasticloadbalancing:SetRulePriorities", "elasticloadbalancing:DeleteRule",
        "elasticloadbalancing:Describe*",
    ],
    "aws_lb_target_group": [
        "elasticloadbalancing:CreateTargetGroup", "elasticloadbalancing:ModifyTargetGroup",
        "elasticloadbalancing:ModifyTargetGroupAttributes",
        "elasticloadbalancing:DeleteTargetGroup", "elasticloadbalancing:Describe*",
    ],
    "aws_s3_bucket": [
        "s3:CreateBucket", "s3:DeleteBucket", "s3:ListBucket", "s3:GetBucketTagging",
        "s3:PutBucketTagging", "s3:DeleteBucketTagging", "s3:DeleteObject",
    ],
    "aws_s3_bucket_lifecycle_configuration": [
        "s3:PutLifecycleConfiguration", "s3:GetLifecycleConfiguration",
    ],
    "aws_s3_bucket_public_access_block": [
        "s3:PutBucketPublicAccessBlock", "s3:GetBucketPublicAccessBlock",
        "s3:DeleteBucketPublicAccessBlock",
    ],
    "aws_s3_bucket_server_side_encryption_configuration": [
        "s3:PutEncryptionConfiguration", "s3:GetEncryptionConfiguration",
        "s3:DeleteBucketEncryption",
    ],
    "aws_s3_bucket_versioning": [
        "s3:PutBucketVersioning", "s3:GetBucketVersioning",
    ],
    "aws_security_group": [
        "ec2:CreateSecurityGroup", "ec2:DeleteSecurityGroup", "ec2:Describe*",
    ],
    "aws_vpc_security_group_egress_rule": [
        "ec2:AuthorizeSecurityGroupEgress", "ec2:RevokeSecurityGroupEgress",
        "ec2:ModifySecurityGroupRules",
    ],
    "aws_vpc_security_group_ingress_rule": [
        "ec2:AuthorizeSecurityGroupIngress", "ec2:RevokeSecurityGroupIngress",
        "ec2:ModifySecurityGroupRules",
    ],
}

RESOURCE_RE = re.compile(r'^\s*resource\s+"(aws_[a-z0-9_]+)"', re.MULTILINE)
DEPLOY_DOC_RE = re.compile(
    r'^data\s+"aws_iam_policy_document"\s+"deploy_\w+"\s*\{.*?^\}', re.MULTILINE | re.DOTALL
)
ACTION_RE = re.compile(r'"([a-z0-9-]+:[A-Za-z0-9*]+)"')


def module_resources():
    """Map each resource type to the module files that declare it."""
    found = {}
    for path in sorted(MODULE.glob("*.tf")):
        for rtype in RESOURCE_RE.findall(path.read_text(encoding="utf-8")):
            found.setdefault(rtype, []).append(path.name)
    return found


def granted_actions():
    text = OIDC.read_text(encoding="utf-8")
    return {a for doc in DEPLOY_DOC_RE.findall(text) for a in ACTION_RE.findall(doc)}


class DeployRoleCoverageTests(unittest.TestCase):
    def test_module_declares_no_iam_policies(self):
        bad = [
            f"modules/fargate-service/{name} declares {rtype}; IAM policies are "
            "bootstrap-owned: add the statement in bootstrap/oidc.tf and have the "
            "module only attach it by ARN (see 9084b6d)"
            for rtype, names in module_resources().items()
            if rtype.startswith("aws_iam_") and rtype not in ALLOWED_IAM_RESOURCES
            for name in names
        ]
        self.assertEqual(bad, [], "\n".join(bad))

    def test_every_module_resource_is_in_the_coverage_table(self):
        unknown = [
            f"modules/fargate-service/{names[0]} declares {rtype}, which is not in "
            "DEPLOY_ROLE_ACTIONS (tests/test_deploy_role_coverage.py): add it with the "
            "IAM actions the deploy role needs, and grant them in bootstrap/oidc.tf"
            for rtype, names in module_resources().items()
            if rtype not in DEPLOY_ROLE_ACTIONS
        ]
        self.assertEqual(unknown, [], "\n".join(unknown))

    def test_deploy_role_grants_every_action_the_module_needs(self):
        granted = granted_actions()
        missing = [
            f"{rtype} ({', '.join(names)}) needs {action}, which no deploy_*_permissions "
            "policy in bootstrap/oidc.tf grants; add it there (see 9a1306a)"
            for rtype, names in module_resources().items()
            for action in DEPLOY_ROLE_ACTIONS.get(rtype, [])
            if action not in granted
        ]
        self.assertEqual(missing, [], "\n".join(missing))


if __name__ == "__main__":
    unittest.main()
