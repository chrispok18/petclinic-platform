# GitHub Actions OIDC federation (technical-spec: CI/CD Pipeline > OIDC Federation). PETPLAT-52.
# No long-lived AWS credentials in GitHub: workflows assume this role via sts:AssumeRoleWithWebIdentity.
#
# The OIDC provider is account-global (one per URL per account). The first environment creates it
# (create_oidc_provider = true); any other root module must set it to false and the provider is
# looked up with a data source instead.

locals {
  oidc_url = "https://token.actions.githubusercontent.com"

  oidc_provider_arn = (
    var.create_oidc_provider
    ? aws_iam_openid_connect_provider.github[0].arn
    : data.aws_iam_openid_connect_provider.github[0].arn
  )

  # GitHub can issue the sub claim in the plain form (repo:owner/name:ref:...) or, when the repo opts
  # into immutable identifiers, as repo:owner@<owner_id>/name@<repo_id>:ref:... Accept both if given.
  repository_forms = compact([var.github_repository, var.github_repository_immutable])

  subjects = flatten([
    for repo in local.repository_forms : [
      for ref in var.allowed_refs : "repo:${repo}:ref:${ref}"
    ]
  ])
}

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 1 : 0

  url            = local.oidc_url
  client_id_list = ["sts.amazonaws.com"]
  # AWS no longer validates GitHub's thumbprint (trusted root CA library), but the field is still
  # accepted; these are GitHub's published intermediate thumbprints.
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd",
  ]

  tags = merge(var.tags, { Name = "github-actions-oidc" })
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 0 : 1

  url = local.oidc_url
}

data "aws_iam_policy_document" "assume_role" {
  statement {
    sid     = "GitHubActionsOIDC"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # StringEquals (not StringLike): only the exact repo + branch may assume the role.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.subjects
    }
  }
}

resource "aws_iam_role" "github_actions" {
  name                 = var.role_name
  description          = "Assumed by GitHub Actions (${var.github_repository}) via OIDC to push images to ECR"
  assume_role_policy   = data.aws_iam_policy_document.assume_role.json
  max_session_duration = 3600

  tags = merge(var.tags, { Name = var.role_name })
}

data "aws_iam_policy_document" "ecr_push" {
  # GetAuthorizationToken does not support resource-level permissions; "*" is the only valid resource.
  statement {
    sid       = "EcrLogin"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "EcrPushToPetclinicRepos"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = var.ecr_repository_arns
  }
}

resource "aws_iam_role_policy" "ecr_push" {
  name   = "${var.role_name}-ecr-push"
  role   = aws_iam_role.github_actions.id
  policy = data.aws_iam_policy_document.ecr_push.json
}
