provider "aws" {
  region = var.aws_region

  # Required tags (technical-spec: Required Tags) applied to every taggable resource.
  default_tags {
    tags = local.common_tags
  }
}
