locals {
  budget_name = "${var.project_name}-${var.environment}-account-annual-cost"
  common_tags = merge(
    {
      Environment = var.environment
      Project     = var.project_name
    },
    var.tags,
  )
}

resource "aws_budgets_budget" "account_annual" {
  name         = local.budget_name
  budget_type  = "COST"
  limit_amount = tostring(var.annual_limit_usd)
  limit_unit   = "USD"
  time_unit    = "ANNUALLY"

  cost_types {
    include_credit = false
    include_refund = false
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    notification_type          = "ACTUAL"
    threshold                  = var.actual_warning_percentage
    threshold_type             = "PERCENTAGE"
    subscriber_email_addresses = [var.notification_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    notification_type          = "FORECASTED"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    subscriber_email_addresses = [var.notification_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    notification_type          = "ACTUAL"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    subscriber_email_addresses = [var.notification_email]
  }

  tags = local.common_tags
}
