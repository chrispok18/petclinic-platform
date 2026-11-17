# ECR module (technical-spec: ECR Container Registry). PETPLAT-18, 19, 20.
# One private repository per service, named petclinic-{env}/{service}.

resource "aws_ecr_repository" "service" {
  for_each = toset(var.service_names)

  name                 = "${var.name_prefix}/${each.key}"
  image_tag_mutability = var.image_tag_mutability
  force_delete         = var.force_delete

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = merge(var.tags, {
    Name    = "${var.name_prefix}/${each.key}"
    Service = each.key
  })
}

resource "aws_ecr_lifecycle_policy" "service" {
  for_each = aws_ecr_repository.service

  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last ${var.max_image_count} images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = var.max_image_count
        }
        action = { type = "expire" }
      }
    ]
  })
}
