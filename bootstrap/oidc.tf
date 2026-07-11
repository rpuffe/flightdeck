# GitHub Actions OIDC federation + deploy role (spec 5, 5b).
# Net-new resources only — nothing here imports or touches pre-existing IAM.

# AWS now validates GitHub's TLS cert against its own trusted-CA library, so
# thumbprints are ignored for this issuer; thumbprint_list has been Optional
# in the provider since v5.31 (and remains so in v6). Omitting it beats
# pinning a stale fingerprint.
resource "aws_iam_openid_connect_provider" "github_actions" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_policy_document" "github_actions_assume" {
  statement {
    sid     = "GitHubActionsFederation"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github_actions.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Owner-wide trust (any repo under var.github_owner) is deliberate v1
    # scope: new app repos onboard with zero platform changes. Tightening to
    # an explicit repo list is future work. Two ref patterns only: main
    # (dev deploys) and v* tags (prod promotion) — PR refs are deliberately
    # excluded, so pull requests run with zero cloud credentials.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${var.github_owner}/*:ref:refs/heads/main",
        "repo:${var.github_owner}/*:ref:refs/tags/v*",
      ]
    }
  }
}

resource "aws_iam_role" "deploy" {
  name               = "${local.name_prefix}-deploy"
  assume_role_policy = data.aws_iam_policy_document.github_actions_assume.json
}

data "aws_iam_policy_document" "deploy_permissions" {
  # --- ECR ---

  # GetAuthorizationToken has no resource-level support; wildcard is unavoidable.
  statement {
    sid       = "EcrAuthToken"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "EcrPushPull"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:PutImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeRepositories",
      "ecr:DescribeImages",
      "ecr:ListImages",
    ]
    resources = [
      "arn:aws:ecr:${var.region}:${data.aws_caller_identity.current.account_id}:repository/${local.name_prefix}/*",
    ]
  }

  # --- ECS ---

  # RegisterTaskDefinition (and the task-definition read/deregister family
  # Terraform calls around it) does not support resource-level scoping on
  # create. Tighten later if AWS adds it.
  statement {
    sid = "EcsTaskDefinitionUnscoped"
    actions = [
      "ecs:RegisterTaskDefinition",
      "ecs:DeregisterTaskDefinition",
      "ecs:DescribeTaskDefinition",
    ]
    resources = ["*"]
  }

  statement {
    sid = "EcsServices"
    actions = [
      "ecs:CreateService",
      "ecs:UpdateService",
      "ecs:DeleteService",
      "ecs:DescribeServices",
      "ecs:DescribeClusters",
      "ecs:TagResource",
      "ecs:UntagResource",
      "ecs:ListTagsForResource",
    ]
    resources = [
      "arn:aws:ecs:${var.region}:${data.aws_caller_identity.current.account_id}:cluster/${local.name_prefix}*",
      # Long-format service ARN embeds the cluster name, which carries the prefix.
      "arn:aws:ecs:${var.region}:${data.aws_caller_identity.current.account_id}:service/${local.name_prefix}*/*",
      "arn:aws:ecs:${var.region}:${data.aws_caller_identity.current.account_id}:task-definition/${local.name_prefix}*:*",
    ]
  }

  # --- ALB: listener rules + target groups ---

  # elasticloadbalancing:Describe* has no resource-level support; wildcard is
  # unavoidable (read-only).
  statement {
    sid       = "ElbRead"
    actions   = ["elasticloadbalancing:Describe*"]
    resources = ["*"]
  }

  statement {
    sid = "ElbWrite"
    actions = [
      "elasticloadbalancing:CreateTargetGroup",
      "elasticloadbalancing:ModifyTargetGroup",
      "elasticloadbalancing:ModifyTargetGroupAttributes",
      "elasticloadbalancing:DeleteTargetGroup",
      "elasticloadbalancing:CreateRule",
      "elasticloadbalancing:ModifyRule",
      "elasticloadbalancing:SetRulePriorities",
      "elasticloadbalancing:DeleteRule",
      "elasticloadbalancing:AddTags",
      "elasticloadbalancing:RemoveTags",
    ]
    # Listener/rule ARNs only embed the load balancer name, so this relies on
    # the ALB itself carrying the flightdeck prefix (spec 5b naming convention).
    resources = [
      "arn:aws:elasticloadbalancing:${var.region}:${data.aws_caller_identity.current.account_id}:targetgroup/${local.name_prefix}*/*",
      "arn:aws:elasticloadbalancing:${var.region}:${data.aws_caller_identity.current.account_id}:listener/app/${local.name_prefix}*/*/*",
      "arn:aws:elasticloadbalancing:${var.region}:${data.aws_caller_identity.current.account_id}:listener-rule/app/${local.name_prefix}*/*/*/*",
    ]
  }

  # --- CloudWatch Logs + alarms ---

  statement {
    sid = "LogGroups"
    actions = [
      "logs:CreateLogGroup",
      "logs:DeleteLogGroup",
      "logs:PutRetentionPolicy",
      "logs:TagResource",
      "logs:UntagResource",
      "logs:ListTagsForResource",
    ]
    resources = [
      "arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:${local.name_prefix}*",
    ]
  }

  # DescribeLogGroups is a list call the provider issues unscoped; it cannot
  # be restricted to a name prefix (read-only).
  statement {
    sid       = "LogGroupsList"
    actions   = ["logs:DescribeLogGroups"]
    resources = ["arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:*"]
  }

  statement {
    sid = "CloudWatchAlarms"
    actions = [
      "cloudwatch:PutMetricAlarm",
      "cloudwatch:DeleteAlarms",
      "cloudwatch:DescribeAlarms",
      "cloudwatch:TagResource",
      "cloudwatch:UntagResource",
      "cloudwatch:ListTagsForResource",
    ]
    resources = [
      "arn:aws:cloudwatch:${var.region}:${data.aws_caller_identity.current.account_id}:alarm:${local.name_prefix}*",
    ]
  }

  # --- EC2: per-app task security groups (created by the fargate-service module) ---

  # ec2:Describe* has no resource-level support; wildcard is unavoidable (read-only).
  statement {
    sid       = "Ec2Read"
    actions   = ["ec2:Describe*"]
    resources = ["*"]
  }

  # CreateSecurityGroup authorizes against both the vpc and the security-group
  # resource; the RequestTag condition can only be evaluated on the latter, so
  # the two resource types need separate statements.
  statement {
    sid       = "TaskSgCreateVpc"
    actions   = ["ec2:CreateSecurityGroup"]
    resources = ["arn:aws:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:vpc/*"]
  }

  statement {
    sid       = "TaskSgCreate"
    actions   = ["ec2:CreateSecurityGroup"]
    resources = ["arn:aws:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:security-group/*"]

    # Provider default_tags send project=flightdeck at creation time.
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/project"
      values   = ["flightdeck"]
    }
  }

  statement {
    sid     = "TaskSgTagOnCreate"
    actions = ["ec2:CreateTags"]
    resources = [
      "arn:aws:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:security-group/*",
      "arn:aws:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:security-group-rule/*",
    ]

    condition {
      test     = "StringEquals"
      variable = "ec2:CreateAction"
      values = [
        "CreateSecurityGroup",
        "AuthorizeSecurityGroupIngress",
        "AuthorizeSecurityGroupEgress",
      ]
    }
  }

  # Mutations only on SGs already tagged as flightdeck's — pre-existing
  # security groups in the account are untouchable (spec 5b).
  statement {
    sid = "TaskSgMutate"
    actions = [
      "ec2:AuthorizeSecurityGroupIngress",
      "ec2:AuthorizeSecurityGroupEgress",
      "ec2:RevokeSecurityGroupIngress",
      "ec2:RevokeSecurityGroupEgress",
      "ec2:ModifySecurityGroupRules",
      "ec2:DeleteSecurityGroup",
    ]
    resources = ["arn:aws:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:security-group/*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/project"
      values   = ["flightdeck"]
    }
  }

  # Rule actions authorize against BOTH the security-group and the
  # security-group-rule resource; rules carry no tags at authorize time, so
  # the tag condition can never match this resource type. Unconditioned here
  # is still safe: IAM requires the paired security-group resource above,
  # which stays tag-guarded.
  statement {
    sid = "TaskSgRules"
    actions = [
      "ec2:AuthorizeSecurityGroupIngress",
      "ec2:AuthorizeSecurityGroupEgress",
      "ec2:RevokeSecurityGroupIngress",
      "ec2:RevokeSecurityGroupEgress",
      "ec2:ModifySecurityGroupRules",
    ]
    resources = ["arn:aws:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:security-group-rule/*"]
  }

  # --- IAM: app task roles ---

  # Tighten later: role-management verbs (esp. PutRolePolicy) on flightdeck-*
  # still let a compromised workflow write arbitrary policies onto task roles;
  # a permissions boundary enforced via iam:PermissionsBoundary condition is
  # the proper fix.
  statement {
    sid = "TaskRoleLifecycle"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:GetRole",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:PutRolePolicy",
      "iam:GetRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:ListRolePolicies",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfilesForRole",
    ]
    resources = [
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${local.name_prefix}-*",
    ]
  }

  statement {
    sid     = "PassTaskRolesToEcsOnly"
    actions = ["iam:PassRole"]
    resources = [
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${local.name_prefix}-*",
    ]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }

  # --- App data buckets (manifest `storage: s3`, v0.4.0) ---

  # Resource-scoped wildcard on purpose: terraform reads every bucket
  # sub-resource (versioning, encryption, ACLs, CORS, lifecycle, ...) on
  # refresh, and enumerating ~30 Get*/Put* actions adds noise, not safety.
  # The *-data-* pattern cannot match the tfstate bucket, so state stays
  # governed by the narrower statements below.
  statement {
    sid     = "AppDataBuckets"
    actions = ["s3:*"]
    resources = [
      "arn:aws:s3:::flightdeck-*-data-*",
      "arn:aws:s3:::flightdeck-*-data-*/*",
    ]
  }

  # --- Terraform state (S3 backend, native lockfile) ---

  statement {
    sid       = "StateBucketList"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::${local.state_bucket_name}"]
  }

  # Tighten later: restrict to apps/* keys once the per-app state layout from
  # spec 5a is locked in, so CI can never touch the bootstrap state object.
  statement {
    sid = "StateObjects"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = ["arn:aws:s3:::${local.state_bucket_name}/*"]
  }
}

resource "aws_iam_role_policy" "deploy" {
  name   = "${local.name_prefix}-deploy-permissions"
  role   = aws_iam_role.deploy.id
  policy = data.aws_iam_policy_document.deploy_permissions.json
}

output "oidc_provider_arn" {
  description = "ARN of the GitHub Actions OIDC provider"
  value       = aws_iam_openid_connect_provider.github_actions.arn
}

output "deploy_role_arn" {
  description = "ARN of the role GitHub Actions assumes to deploy apps"
  value       = aws_iam_role.deploy.arn
}
