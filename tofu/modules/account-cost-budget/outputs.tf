output "arn" {
  description = "ARN of the account-wide annual cost budget."
  value       = aws_budgets_budget.account_annual.arn
}

output "name" {
  description = "Name of the account-wide annual cost budget."
  value       = aws_budgets_budget.account_annual.name
}

output "settings" {
  description = "Auditable scope, limit, period, and notification thresholds for the annual budget."
  value = {
    scope                     = "account"
    limit_amount_usd          = var.annual_limit_usd
    time_unit                 = "ANNUALLY"
    actual_warning_percentage = var.actual_warning_percentage
    actual_limit_percentage   = 100
    forecast_limit_percentage = 100
    actions_enabled           = false
    include_credits           = false
    include_refunds           = false
  }
}
