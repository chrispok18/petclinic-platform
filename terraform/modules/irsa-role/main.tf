# Generic IRSA role (technical-spec: IRSA Roles > IRSA Trust Policy Template).
# Trust is scoped to exactly one ServiceAccount in one namespace, audience sts.amazonaws.com.

data "aws_iam_policy_document" "trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:${var.namespace}:${var.service_account}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name               = var.role_name
  description        = "IRSA role for ${var.namespace}/${var.service_account}"
  assume_role_policy = data.aws_iam_policy_document.trust.json

  tags = merge(var.tags, { Name = var.role_name })
}

resource "aws_iam_policy" "this" {
  name        = "${var.role_name}-policy"
  description = "Permissions for ${var.namespace}/${var.service_account}"
  policy      = var.policy_json

  tags = merge(var.tags, { Name = "${var.role_name}-policy" })
}

resource "aws_iam_role_policy_attachment" "this" {
  role       = aws_iam_role.this.name
  policy_arn = aws_iam_policy.this.arn
}
