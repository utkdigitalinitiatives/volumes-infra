# ------------------------------------------------------------------------------
# DevTest Environment - Persistent backing services for environments/dev/
# ------------------------------------------------------------------------------
# What this stack owns (all in <project>-devtest-rg):
#   - PostgreSQL Flexible Server: <project>-devtest-psql (Burstable B1ms)
#   - Blob storage account:       <storage_prefix>devtest<rand> (drupal-media container)
#   - Automation Account:         <project>-devtest-automation (weekly auto-stop)
#
# Lifecycle: applied manually, set-and-forget. These resources persist
# indefinitely and are NOT touched by any CI/CD workflow.
#
# Consumer: environments/dev/ (the ephemeral dev VM) connects to the PostgreSQL
# server above and reads its storage account key from Key Vault. This stack
# writes `devtest-storage-account-key` to KV for that purpose.
#
# Database refresh: the dev-merge workflow runs pg_dump from production and
# pg_restore into this server before each dev VM deploy.
#
# State key: devtest/terraform.tfstate
# Apply order: secrets -> devtest -> production / dev
# ------------------------------------------------------------------------------

terraform {
  required_version = ">= 1.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.71"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.8"
    }
  }

  backend "azurerm" {}
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

locals {
  environment = "devtest"
  common_tags = {
    Environment = local.environment
    ManagedBy   = "terraform"
    Project     = var.project_name
    CostCenter  = var.cost_center
  }
}

data "azurerm_resource_group" "devtest" {
  name = "${var.project_name}-devtest-rg"
}

# Shared Key Vault provisioned by environments/secrets/.
# The backend coordinates are variables rather than repeated literals so a third
# site is a tfvars change instead of a fork.
data "terraform_remote_state" "secrets" {
  backend = "azurerm"
  config = {
    resource_group_name  = var.tfstate_resource_group_name
    storage_account_name = var.tfstate_storage_account_name
    container_name       = var.tfstate_container_name
    key                  = "secrets/terraform.tfstate"
    use_oidc             = var.use_oidc
    use_azuread_auth     = var.use_azuread_auth
  }
}

data "azurerm_key_vault_secret" "db_admin_password" {
  name         = "devtest-db-admin-password"
  key_vault_id = data.terraform_remote_state.secrets.outputs.key_vault_id
}

# Mirror the devtest storage account access key into KV. Consumed by the dev VM
# env (environments/dev/) via a data source, so the dev workflow does not need
# `az storage account keys list` at runtime.
resource "azurerm_key_vault_secret" "storage_account_key" {
  name         = "devtest-storage-account-key"
  value        = module.blob_storage.primary_access_key
  key_vault_id = data.terraform_remote_state.secrets.outputs.key_vault_id
  content_type = "text/plain"
}

module "postgresql" {
  source = "../../modules/postgresql"

  project_name           = var.project_name
  environment            = local.environment
  resource_group_name    = data.azurerm_resource_group.devtest.name
  location               = var.location
  sku_name               = "B_Standard_B1ms"
  administrator_login    = var.db_admin_username
  administrator_password = data.azurerm_key_vault_secret.db_admin_password.value
  database_name          = var.db_name
  backup_retention_days  = 7
  allow_azure_services   = true

  tags = merge(local.common_tags, {
    AutoStop = "true"
  })
}

module "blob_storage" {
  source = "../../modules/blob-storage"

  project_name               = var.project_name
  storage_prefix             = var.storage_prefix
  environment                = local.environment
  resource_group_name        = data.azurerm_resource_group.devtest.name
  location                   = var.location
  container_name             = "drupal-media"
  replication_type           = "LRS"
  soft_delete_retention_days = 7
  enable_versioning          = false

  disable_defender_for_storage = true

  # Developers who may read devtest data: the shared drupal-media container and
  # the db-dumps container below. Read-only, scoped per container.
  # AAD object IDs are personal identifiers and this repository is public, so
  # they live in the gitignored terraform.tfvars, not here.
  # Collect via: az ad user show --id <email> --query id -o tsv
  developer_identities = var.developer_identities

  # Private container that .github/workflows/dump-production-db.yml writes
  # production dumps into, so devs can seed their local DDEV. Neither Cloud
  # Shell nor a laptop can reach the PostgreSQL servers directly, and Actions
  # artifacts are unsafe in a public repo. Treat this repo as public.
  enable_db_dumps_container = true
  db_dumps_container_name   = "db-dumps"
  db_dump_retention_days    = 7

  tags = local.common_tags
}

module "automation" {
  source = "../../modules/azure-automation"

  project_name        = var.project_name
  environment         = local.environment
  resource_group_name = data.azurerm_resource_group.devtest.name
  location            = var.location

  tags = local.common_tags
}
