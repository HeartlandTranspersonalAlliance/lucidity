resource "aws_ecr_repository" "bootc" {
  for_each = var.repository_names

  name                 = each.value
  image_tag_mutability = length(var.mutable_channel_tags) > 0 ? "IMMUTABLE_WITH_EXCLUSION" : "IMMUTABLE"

  dynamic "image_tag_mutability_exclusion_filter" {
    for_each = var.mutable_channel_tags

    content {
      filter      = image_tag_mutability_exclusion_filter.value
      filter_type = "WILDCARD"
    }
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "bootc" {
  for_each = aws_ecr_repository.bootc

  repository = each.value.name
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images while retaining immutable release tags"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = var.expire_untagged_after_days
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}
