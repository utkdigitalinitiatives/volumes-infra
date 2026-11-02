# ------------------------------------------------------------------------------
# Secrets Environment
# ------------------------------------------------------------------------------
# Provisions the single shared Azure Key Vault used by production + devtest + dev.
# Lives in its own resource group (<project>-secrets-rg) so its lifecycle is
# decoupled from any application environment.
#
# Application envs consume the vault via `data "azurerm_key_vault"` and grant
# their own VMSS / VM managed identities Key Vault Secrets User at vault scope.
#
# The resource group is NOT created here. bootstrap/azure-setup.sh creates every
# resource group up front so the GitHub Actions service principal can be scoped
# to them individually instead of holding subscription-wide Contributor. Terraform
# reads them with a data source. (lib-main creates the RG in both the bootstrap
# script and the Terraform stack, which forces a `terraform import` on first apply.)
#
# Deployment:
#   terraform init -backend-config=backend.hcl \
#     -backend-config="use_oidc=true" \
#     -backend-config="use_azuread_auth=true"
#   terraform apply
#
# State key: secrets/terraform.tfstate
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
  features {
    key_vault {
      purge_soft_deleted_secrets_on_destroy = true
      recover_soft_deleted_secrets          = true
    }
  }
  subscription_id = var.subscription_id
}

locals {
  environment = "secrets"
  common_tags = {
    Environment = local.environment
    ManagedBy   = "terraform"
    Project     = var.project_name
    CostCenter  = var.cost_center
  }
}

data "azurerm_client_config" "current" {}

data "azurerm_resource_group" "secrets" {
  name = "${var.project_name}-secrets-rg"
}

# Random suffix keeps the vault name globally unique without depending on a
# hand-picked value. Key Vault names are capped at 24 characters:
# "volumes-kv-" (11) + 8 hex = 19.
resource "random_id" "kv_suffix" {
  byte_length = 4
}

resource "azurerm_key_vault" "shared" {
  name                = "${var.project_name}-kv-${random_id.kv_suffix.hex}"
  location            = data.azurerm_resource_group.secrets.location
  resource_group_name = data.azurerm_resource_group.secrets.name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"

  rbac_authorization_enabled = true
  purge_protection_enabled   = true
  soft_delete_retention_days = 90

  # Network ACLs intentionally permissive: RBAC is the primary authn boundary.
  # GitHub-hosted runner egress IPs change frequently, and locking ip_rules to
  # them creates ongoing maintenance.
  network_acls {
    bypass         = "AzureServices"
    default_action = "Allow"
  }

  tags = local.common_tags
}

# GitHub Actions service principal: needs to set + read secrets during apply and
# read for pg_dump/pg_restore. Object ID (not app/client ID) required.
resource "azurerm_role_assignment" "gh_actions_secrets_officer" {
  scope                = azurerm_key_vault.shared.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = var.gh_actions_sp_object_id
}

# Operators: full read/write on secrets for manual rotation and troubleshooting.
resource "azurerm_role_assignment" "operator_secrets_officer" {
  for_each             = toset(var.operator_object_ids)
  scope                = azurerm_key_vault.shared.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = each.value
}
