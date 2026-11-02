# ------------------------------------------------------------------------------
# Azure Automation Module
# ------------------------------------------------------------------------------
# Creates an Azure Automation Account with a weekly runbook to stop
# tagged PostgreSQL Flexible Servers. Used to manage costs for the
# permanent devtest PostgreSQL instance.
#
# Resources:
#   - Automation Account with SystemAssigned identity
#   - Contributor role on target resource group
#   - PowerShell 7.2 runbook (Stop-TaggedPostgreSql)
#   - Weekly schedule with configurable timezone
# ------------------------------------------------------------------------------

terraform {
  required_version = ">= 1.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.71"
    }
  }
}

locals {
  account_name = "${var.project_name}-${var.environment}-automation"
  common_tags = merge(var.tags, {
    Environment = var.environment
    ManagedBy   = "terraform"
    Project     = var.project_name
  })
}

resource "azurerm_automation_account" "main" {
  name                = local.account_name
  location            = var.location
  resource_group_name = var.resource_group_name
  sku_name            = "Basic"

  identity {
    type = "SystemAssigned"
  }

  tags = local.common_tags
}

# Grant the automation identity Contributor on the resource group
# so it can stop PostgreSQL servers
resource "azurerm_role_assignment" "automation_contributor" {
  scope                = "/subscriptions/${data.azurerm_subscription.current.subscription_id}/resourceGroups/${var.resource_group_name}"
  role_definition_name = "Contributor"
  principal_id         = azurerm_automation_account.main.identity[0].principal_id
}

data "azurerm_subscription" "current" {}

resource "azurerm_automation_runbook" "stop_postgresql" {
  name                    = "Stop-TaggedPostgreSql"
  location                = var.location
  resource_group_name     = var.resource_group_name
  automation_account_name = azurerm_automation_account.main.name
  log_verbose             = false
  log_progress            = false
  runbook_type            = "PowerShell72"

  content = file("${path.module}/scripts/Stop-TaggedPostgreSql.ps1")

  tags = local.common_tags

  # azurerm 4.81 reads runbook_type back as "PowerShell" for a runbook created
  # as "PowerShell72", so every plan wants to replace this. Azure itself has it
  # right -- `az automation runbook show` reports runbookType: PowerShell72 --
  # so this suppresses a provider misread, not real drift. Re-test on provider
  # upgrades; drop this once the read is fixed upstream.
  lifecycle {
    ignore_changes = [runbook_type]
  }
}

resource "azurerm_automation_schedule" "weekly_stop" {
  name                    = "weekly-stop-postgresql"
  resource_group_name     = var.resource_group_name
  automation_account_name = azurerm_automation_account.main.name
  frequency               = "Week"
  interval                = 1
  timezone                = var.schedule_timezone
  week_days               = var.schedule_week_days

  # Only the time-of-day and the weekday matter for recurrence; the date just
  # anchors the first run, and Azure requires it be in the future at create
  # time. Computing it keeps a fresh bootstrap from failing on a stale literal.
  # The -05:00 offset is EST -- during EDT this shifts only which instant Azure
  # treats as the first occurrence, not the recurring 22:00 local firing, which
  # timezone governs.
  start_time = coalesce(
    var.schedule_start_time,
    "${formatdate("YYYY-MM-DD", timeadd(plantimestamp(), "240h"))}T22:00:00-05:00"
  )

  # start_time is recomputed on every plan. Without this the schedule shows a
  # permanent diff and would be replaced on each apply.
  lifecycle {
    ignore_changes = [start_time]
  }
}

resource "azurerm_automation_job_schedule" "stop_postgresql" {
  resource_group_name     = var.resource_group_name
  automation_account_name = azurerm_automation_account.main.name
  schedule_name           = azurerm_automation_schedule.weekly_stop.name
  runbook_name            = azurerm_automation_runbook.stop_postgresql.name

  # resourcegroupname is passed explicitly. The runbook's managed identity is
  # only Contributor on this resource group, so an unscoped
  # Get-AzPostgreSqlFlexibleServer returns nothing, the runbook takes its
  # "no servers found" branch, reports Completed, and stops nothing. That silent
  # no-op ran undetected on lib-main for at least four consecutive weeks.
  parameters = {
    tagkey            = var.target_tag_key
    tagvalue          = var.target_tag_value
    resourcegroupname = var.resource_group_name
  }
}
