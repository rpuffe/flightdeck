# GitHub Actions OIDC federation + one deploy role per registered app.
# Net-new resources only (spec 5b): no role imports and no changes to
# pre-existing IAM resources.

resource "aws_iam_openid_connect_provider" "github_actions" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

locals {
  app_deploy = {
    for app in toset(var.apps) : app => {
      role_name              = "${local.name_prefix}-deploy-${app}"
      permissions_boundary   = "${local.name_prefix}-${app}-task-boundary"
      service_names          = [app, "${app}-dev"]
      ecr_repository_names   = ["${local.name_prefix}/${app}", "${local.name_prefix}/${app}-dev"]
      data_bucket_names      = ["${local.name_prefix}-${app}-data-${data.aws_caller_identity.current.account_id}", "${local.name_prefix}-${app}-dev-data-${data.aws_caller_identity.current.account_id}"]
      state_object_keys      = ["apps/${app}/terraform.tfstate", "apps/${app}/terraform.tfstate.tflock", "apps/${app}/dev/terraform.tfstate", "apps/${app}/dev/terraform.tfstate.tflock"]
      state_list_prefix      = "apps/${app}/*"
      github_repository_name = app
    }
  }

  app_services = merge([
    for app in toset(var.apps) : {
      for service in [app, "${app}-dev"] : service => {
        app         = app
        bucket_name = "${local.name_prefix}-${service}-data-${data.aws_caller_identity.current.account_id}"
      }
    }
  ]...)
}

data "aws_iam_policy_document" "github_actions_assume" {
  for_each = local.app_deploy

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

    # Exact registered repository only. Pull-request refs, feature branches,
    # non-release tags, and unrelated repositories under the same owner are
    # excluded from the trust policy.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${var.github_owner}/${each.value.github_repository_name}:ref:refs/heads/main",
        "repo:${var.github_owner}/${each.value.github_repository_name}:ref:refs/tags/v*",
      ]
    }
  }
}

resource "aws_iam_role" "deploy" {
  for_each = local.app_deploy

  name               = each.value.role_name
  assume_role_policy = data.aws_iam_policy_document.github_actions_assume[each.key].json
}

# Every task and execution role created by an app deployment must carry this
# app-specific boundary. Even if a trusted workflow writes a malicious inline
# policy, its effective permissions cannot exceed the app's own ECR/log/S3
# resources below.
data "aws_iam_policy_document" "task_permissions_boundary" {
  for_each = local.app_deploy

  statement {
    sid       = "EcrAuthToken"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "PullOwnImages"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = [
      for repository in each.value.ecr_repository_names :
      "arn:aws:ecr:${var.region}:${data.aws_caller_identity.current.account_id}:repository/${repository}"
    ]
  }

  statement {
    sid = "WriteOwnLogs"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = [
      for service in each.value.service_names :
      "arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:${local.name_prefix}/${service}:log-stream:*"
    ]
  }

  statement {
    sid       = "ListOwnStorageBuckets"
    actions   = ["s3:ListBucket"]
    resources = [for bucket in each.value.data_bucket_names : "arn:aws:s3:::${bucket}"]
  }

  statement {
    sid = "ReadWriteOwnStorageObjects"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = [for bucket in each.value.data_bucket_names : "arn:aws:s3:::${bucket}/*"]
  }
}

resource "aws_iam_policy" "task_permissions_boundary" {
  for_each = local.app_deploy

  name        = each.value.permissions_boundary
  description = "Maximum permissions for ${each.key} ECS task and execution roles"
  policy      = data.aws_iam_policy_document.task_permissions_boundary[each.key].json
}

# The only optional task-role grant supported by the manifest. Keeping this as
# a bootstrap-owned managed policy means the deploy role never needs the
# privilege-escalation-prone iam:PutRolePolicy action.
data "aws_iam_policy_document" "task_storage_permissions" {
  for_each = local.app_services

  statement {
    sid       = "ListEnvironmentStorageBucket"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::${each.value.bucket_name}"]
  }

  statement {
    sid = "ReadWriteEnvironmentStorageObjects"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = ["arn:aws:s3:::${each.value.bucket_name}/*"]
  }
}

resource "aws_iam_policy" "task_storage" {
  for_each = local.app_services

  name        = "${local.name_prefix}-${each.key}-task-storage"
  description = "Optional S3 storage permissions for the ${each.key} task role"
  policy      = data.aws_iam_policy_document.task_storage_permissions[each.key].json
}

data "aws_iam_policy_document" "deploy_infrastructure_permissions" {
  for_each = local.app_deploy

  # --- ECR: this app's prod and dev repositories only ---

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
      for repository in each.value.ecr_repository_names :
      "arn:aws:ecr:${var.region}:${data.aws_caller_identity.current.account_id}:repository/${repository}"
    ]
  }

  # --- ECS: this app's prod and dev services/task definitions, except where
  # AWS does not expose resource-level authorization ---

  statement {
    sid     = "EcsTaskDefinitionCreate"
    actions = ["ecs:RegisterTaskDefinition"]
    resources = [
      for service in each.value.service_names :
      "arn:aws:ecs:${var.region}:${data.aws_caller_identity.current.account_id}:task-definition/${local.name_prefix}-${service}:*"
    ]
  }

  # DescribeTaskDefinition does not support resource-level authorization.
  statement {
    sid       = "EcsTaskDefinitionRead"
    actions   = ["ecs:DescribeTaskDefinition"]
    resources = ["*"]
  }

  statement {
    sid     = "EcsTaskDefinitionDelete"
    actions = ["ecs:DeregisterTaskDefinition"]
    # AWS exposes neither a resource type nor an action-specific condition key
    # for DeregisterTaskDefinition, so an exact task-definition ARN never
    # authorizes Terraform's replacement cleanup. Keep the unavoidable
    # wildcard isolated to this one action and bound to Flightdeck's region.
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.region]
    }
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
    resources = concat(
      ["arn:aws:ecs:${var.region}:${data.aws_caller_identity.current.account_id}:cluster/${local.name_prefix}"],
      [for service in each.value.service_names : "arn:aws:ecs:${var.region}:${data.aws_caller_identity.current.account_id}:service/${local.name_prefix}/${service}"],
      [for service in each.value.service_names : "arn:aws:ecs:${var.region}:${data.aws_caller_identity.current.account_id}:task-definition/${local.name_prefix}-${service}:*"],
    )
  }

  # --- ALB: this app's target groups and shared listener rules ---

  statement {
    sid       = "ElbRead"
    actions   = ["elasticloadbalancing:Describe*"]
    resources = ["*"]
  }

  statement {
    sid = "ElbTargetGroups"
    actions = [
      "elasticloadbalancing:CreateTargetGroup",
      "elasticloadbalancing:ModifyTargetGroup",
      "elasticloadbalancing:ModifyTargetGroupAttributes",
      "elasticloadbalancing:DeleteTargetGroup",
      "elasticloadbalancing:AddTags",
      "elasticloadbalancing:RemoveTags",
    ]
    resources = [
      for service in each.value.service_names :
      "arn:aws:elasticloadbalancing:${var.region}:${data.aws_caller_identity.current.account_id}:targetgroup/${local.name_prefix}-${service}/*"
    ]
  }

  # Listener-rule ARNs contain the shared ALB name, not the host condition or
  # app name, so AWS IAM cannot distinguish one app's rule from another here.
  statement {
    sid = "ElbListenerRules"
    actions = [
      "elasticloadbalancing:CreateRule",
      "elasticloadbalancing:ModifyRule",
      "elasticloadbalancing:SetRulePriorities",
      "elasticloadbalancing:DeleteRule",
      "elasticloadbalancing:AddTags",
      "elasticloadbalancing:RemoveTags",
    ]
    resources = [
      "arn:aws:elasticloadbalancing:${var.region}:${data.aws_caller_identity.current.account_id}:listener/app/${local.name_prefix}*/*/*",
      "arn:aws:elasticloadbalancing:${var.region}:${data.aws_caller_identity.current.account_id}:listener-rule/app/${local.name_prefix}*/*/*/*",
    ]
  }

  # --- CloudWatch Logs + alarms: this app only ---

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
    resources = flatten([
      for service in each.value.service_names : [
        "arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:${local.name_prefix}/${service}",
        "arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:${local.name_prefix}/${service}:*",
      ]
    ])
  }

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
      for service in each.value.service_names :
      "arn:aws:cloudwatch:${var.region}:${data.aws_caller_identity.current.account_id}:alarm:${local.name_prefix}-${service}-*"
    ]
  }
}

data "aws_iam_policy_document" "deploy_identity_permissions" {
  for_each = local.app_deploy

  # --- EC2: per-app task security groups ---

  statement {
    sid       = "Ec2Read"
    actions   = ["ec2:Describe*"]
    resources = ["*"]
  }

  statement {
    sid       = "TaskSgCreateVpc"
    actions   = ["ec2:CreateSecurityGroup"]
    resources = ["arn:aws:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:vpc/*"]
  }

  statement {
    sid       = "TaskSgCreate"
    actions   = ["ec2:CreateSecurityGroup"]
    resources = ["arn:aws:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:security-group/*"]

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

  # --- IAM: this app's four bounded task/execution roles only ---

  statement {
    sid     = "TaskRoleCreate"
    actions = ["iam:CreateRole"]
    resources = flatten([
      for service in each.value.service_names : [
        "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${local.name_prefix}-${service}-task",
        "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${local.name_prefix}-${service}-exec",
      ]
    ])

    condition {
      test     = "StringEquals"
      variable = "iam:PermissionsBoundary"
      values   = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/${each.value.permissions_boundary}"]
    }
  }

  statement {
    sid = "TaskRoleReadAndLegacyPolicyCleanup"
    actions = [
      "iam:GetRole",
      "iam:GetRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfilesForRole",
    ]
    resources = flatten([
      for service in each.value.service_names : [
        "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${local.name_prefix}-${service}-task",
        "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${local.name_prefix}-${service}-exec",
      ]
    ])
  }

  # AWS's IAM Service Authorization Reference explicitly lists
  # iam:PermissionsBoundary for DeleteRole and DetachRolePolicy, but not for
  # TagRole/UntagRole or PassRole. Keep tagging exact-resource-scoped here;
  # boundary removal is never granted, arbitrary inline writes are never
  # granted, and managed-policy attachment is allowlisted.
  statement {
    sid = "TaskRoleTagging"
    actions = [
      "iam:TagRole",
      "iam:UntagRole",
    ]
    resources = flatten([
      for service in each.value.service_names : [
        "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${local.name_prefix}-${service}-task",
        "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${local.name_prefix}-${service}-exec",
      ]
    ])

  }

  statement {
    sid = "BoundedTaskRoleCleanup"
    actions = [
      "iam:DeleteRole",
      "iam:DetachRolePolicy",
    ]
    resources = flatten([
      for service in each.value.service_names : [
        "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${local.name_prefix}-${service}-task",
        "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${local.name_prefix}-${service}-exec",
      ]
    ])

    condition {
      test     = "ArnEquals"
      variable = "iam:PermissionsBoundary"
      values   = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/${each.value.permissions_boundary}"]
    }
  }

  statement {
    sid     = "SetRequiredPermissionsBoundary"
    actions = ["iam:PutRolePermissionsBoundary"]
    resources = flatten([
      for service in each.value.service_names : [
        "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${local.name_prefix}-${service}-task",
        "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${local.name_prefix}-${service}-exec",
      ]
    ])

    condition {
      test     = "StringEquals"
      variable = "iam:PermissionsBoundary"
      values   = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/${each.value.permissions_boundary}"]
    }
  }

  statement {
    sid       = "AttachEcsExecutionPolicyOnly"
    actions   = ["iam:AttachRolePolicy"]
    resources = [for service in each.value.service_names : "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${local.name_prefix}-${service}-exec"]

    condition {
      test     = "ArnEquals"
      variable = "iam:PolicyARN"
      values   = ["arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"]
    }

    condition {
      test     = "ArnEquals"
      variable = "iam:PermissionsBoundary"
      values   = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/${each.value.permissions_boundary}"]
    }
  }

  dynamic "statement" {
    for_each = toset(each.value.service_names)

    content {
      actions   = ["iam:AttachRolePolicy"]
      resources = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${local.name_prefix}-${statement.value}-task"]

      condition {
        test     = "ArnEquals"
        variable = "iam:PolicyARN"
        values   = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/${local.name_prefix}-${statement.value}-task-storage"]
      }


      condition {
        test     = "ArnEquals"
        variable = "iam:PermissionsBoundary"
        values   = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/${each.value.permissions_boundary}"]
      }
    }
  }

  statement {
    sid     = "PassTaskRolesToEcsOnly"
    actions = ["iam:PassRole"]
    resources = flatten([
      for service in each.value.service_names : [
        "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${local.name_prefix}-${service}-task",
        "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${local.name_prefix}-${service}-exec",
      ]
    ])

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }


  }
}

data "aws_iam_policy_document" "deploy_data_permissions" {
  for_each = local.app_deploy

  # --- App data buckets: this app's dev/prod buckets only ---

  statement {
    sid = "AppDataBucketLifecycle"
    actions = [
      "s3:CreateBucket",
      "s3:DeleteBucket",
      "s3:DeleteBucketEncryption",
      "s3:DeleteBucketPublicAccessBlock",
      "s3:DeleteBucketTagging",
      "s3:GetAccelerateConfiguration",
      "s3:GetBucketAcl",
      "s3:GetBucketCORS",
      "s3:GetBucketLocation",
      "s3:GetBucketLogging",
      "s3:GetBucketNotification",
      "s3:GetBucketObjectLockConfiguration",
      "s3:GetBucketOwnershipControls",
      "s3:GetBucketPolicy",
      "s3:GetBucketPolicyStatus",
      "s3:GetBucketPublicAccessBlock",
      "s3:GetBucketRequestPayment",
      "s3:GetBucketTagging",
      "s3:GetBucketVersioning",
      "s3:GetBucketWebsite",
      "s3:GetEncryptionConfiguration",
      "s3:GetLifecycleConfiguration",
      "s3:GetReplicationConfiguration",
      "s3:ListBucket",
      "s3:ListBucketVersions",
      "s3:PutBucketPublicAccessBlock",
      "s3:PutBucketTagging",
      "s3:PutEncryptionConfiguration",
    ]
    resources = [for bucket in each.value.data_bucket_names : "arn:aws:s3:::${bucket}"]
  }

  # force_destroy enumerates and removes any app-written objects before the
  # bucket itself is deleted. The deploy role never reads app data objects.
  statement {
    sid       = "DeleteAppDataObjectsForDestroy"
    actions   = ["s3:DeleteObject"]
    resources = [for bucket in each.value.data_bucket_names : "arn:aws:s3:::${bucket}/*"]
  }

  # --- Terraform state: own keys plus read-only bootstrap wiring ---

  statement {
    sid       = "StateBucketListOwnPrefix"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::${local.state_bucket_name}"]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = [each.value.state_list_prefix]
    }
  }

  statement {
    sid = "OwnStateObjects"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = [for key in each.value.state_object_keys : "arn:aws:s3:::${local.state_bucket_name}/${key}"]
  }

  # Interim narrow read required by template-app's terraform_remote_state data
  # source. App roles cannot write or delete bootstrap state.
  statement {
    sid       = "BootstrapStateRead"
    actions   = ["s3:GetObject"]
    resources = ["arn:aws:s3:::${local.state_bucket_name}/bootstrap/terraform.tfstate"]
  }

  statement {
    sid       = "BootstrapStateListExactKey"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::${local.state_bucket_name}"]

    condition {
      test     = "StringEquals"
      variable = "s3:prefix"
      values   = ["bootstrap/terraform.tfstate"]
    }
  }
}

resource "aws_iam_policy" "deploy_infrastructure" {
  for_each = local.app_deploy

  name        = "${local.name_prefix}-deploy-${each.key}-infrastructure"
  description = "ECR, ECS, ALB, logs, and alarms managed by the ${each.key} deploy role"
  policy      = data.aws_iam_policy_document.deploy_infrastructure_permissions[each.key].json
}

resource "aws_iam_policy" "deploy_identity" {
  for_each = local.app_deploy

  name        = "${local.name_prefix}-deploy-${each.key}-identity"
  description = "Network and bounded task-role lifecycle managed by the ${each.key} deploy role"
  policy      = data.aws_iam_policy_document.deploy_identity_permissions[each.key].json
}

resource "aws_iam_policy" "deploy_data" {
  for_each = local.app_deploy

  name        = "${local.name_prefix}-deploy-${each.key}-data"
  description = "App data and isolated Terraform state managed by the ${each.key} deploy role"
  policy      = data.aws_iam_policy_document.deploy_data_permissions[each.key].json
}

resource "aws_iam_role_policy_attachment" "deploy_infrastructure" {
  for_each = local.app_deploy

  role       = aws_iam_role.deploy[each.key].name
  policy_arn = aws_iam_policy.deploy_infrastructure[each.key].arn
}

resource "aws_iam_role_policy_attachment" "deploy_identity" {
  for_each = local.app_deploy

  role       = aws_iam_role.deploy[each.key].name
  policy_arn = aws_iam_policy.deploy_identity[each.key].arn
}

resource "aws_iam_role_policy_attachment" "deploy_data" {
  for_each = local.app_deploy

  role       = aws_iam_role.deploy[each.key].name
  policy_arn = aws_iam_policy.deploy_data[each.key].arn
}

output "oidc_provider_arn" {
  description = "ARN of the GitHub Actions OIDC provider"
  value       = aws_iam_openid_connect_provider.github_actions.arn
}

output "deploy_role_arns" {
  description = "Map of registered app name to its repository-specific GitHub Actions deploy role ARN"
  value       = { for app, role in aws_iam_role.deploy : app => role.arn }
}

output "task_permissions_boundary_arns" {
  description = "Map of registered app name to the mandatory permissions boundary for its ECS task and execution roles"
  value       = { for app, policy in aws_iam_policy.task_permissions_boundary : app => policy.arn }
}
