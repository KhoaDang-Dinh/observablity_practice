# FinOps controls are opt-in because Billing APIs require permissions that
# are usually broader than ordinary infrastructure deployment permissions.

resource "aws_ce_cost_allocation_tag" "project" {
  count    = var.enable_aws_finops ? 1 : 0
  provider = aws.billing

  tag_key = "Project"
  status  = "Active"
}

resource "aws_ce_cost_allocation_tag" "environment" {
  count    = var.enable_aws_finops ? 1 : 0
  provider = aws.billing

  tag_key = "Environment"
  status  = "Active"
}

resource "aws_ce_cost_allocation_tag" "component" {
  count    = var.enable_aws_finops ? 1 : 0
  provider = aws.billing

  tag_key = "Component"
  status  = "Active"
}

resource "aws_budgets_budget" "project_monthly" {
  count    = var.enable_aws_finops ? 1 : 0
  provider = aws.billing

  name         = "${var.cluster_name}-monthly-cost"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name   = "TagKeyValue"
    values = ["user:Project$day3-cicd-lgtm"]
  }

  dynamic "notification" {
    for_each = var.budget_alert_email == "" ? [] : [80, 100]
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value
      threshold_type             = "PERCENTAGE"
      notification_type          = notification.value == 100 ? "FORECASTED" : "ACTUAL"
      subscriber_email_addresses = [var.budget_alert_email]
    }
  }

  depends_on = [
    aws_ce_cost_allocation_tag.project,
    aws_ce_cost_allocation_tag.environment,
    aws_ce_cost_allocation_tag.component,
  ]
}
