# ------------------------------------------------------------------------------
# Dev Environment — Ephemeral validation VM (CI-driven; do not apply locally)
# ------------------------------------------------------------------------------
# What this stack owns (in <project>-dev-rg):
#   - A single Drupal VM, replaced on every app-repo dev-branch merge
#
# Backing services come from environments/devtest/:
#   - PostgreSQL:     var.devtest_db_host -> the devtest PostgreSQL FQDN
#   - Blob storage:   var.devtest_storage_account -> the devtest storage account
#   - Storage key + hash salt: read from the shared Key Vault (<project>-kv-*)
#
# Lifecycle (fully automated by GitHub Actions — do not run terraform locally):
#   1. Push to the app repo `dev` branch triggers repository_dispatch (drupal-dev-merge)
#   2. build-on-dispatch.yml: Packer builds new image, prod DB synced into
#      devtest PostgreSQL, blob assets synced into devtest storage, then THIS
#      stack is `terraform apply`-ed to deploy the VM with the new image.
#   3. Developer validates the dev VM, then merges dev -> main.
#   4. deploy-on-main-merge.yml: production deploys, then THIS stack is
#      `terraform destroy`-ed.
#
# State key: dev/terraform.tfstate
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

  # Backend configuration for Terraform state
  # Uses partial configuration - remaining values passed via -backend-config
  # State key: dev/terraform.tfstate (shared across dev deploys)
  backend "azurerm" {}
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

# Random hash salt for Drupal security
resource "random_password" "drupal_hash_salt" {
  length  = 64
  special = true
}

# Shared Key Vault provisioned by environments/secrets/.
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

# Allow the dev VM managed identity to read secrets from the shared vault at boot.
# The dev VM connects to the devtest PostgreSQL server, so it reads
# devtest-db-admin-password.
resource "azurerm_role_assignment" "dev_vm_kv_secrets_user" {
  scope                = data.terraform_remote_state.secrets.outputs.key_vault_id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = module.dev_vm.vm_identity_principal_id
}

# Persist the dev VM's hash salt to KV so it survives state churn.
resource "azurerm_key_vault_secret" "drupal_hash_salt" {
  name         = "dev-drupal-hash-salt"
  value        = random_password.drupal_hash_salt.result
  key_vault_id = data.terraform_remote_state.secrets.outputs.key_vault_id
  content_type = "text/plain"
}

# Anubis signing key. The dev VM is a single instance, so sharing does not
# matter here, but it goes through Key Vault like production's so a dev deploy
# exercises the same fetch path. Recreated with the stack on every deploy.
resource "random_bytes" "anubis_signing_key" {
  length = 32
}

resource "azurerm_key_vault_secret" "anubis_signing_key" {
  name         = "dev-anubis-signing-key"
  value        = random_bytes.anubis_signing_key.hex
  key_vault_id = data.terraform_remote_state.secrets.outputs.key_vault_id
  content_type = "text/plain"
}

# Read the devtest storage account key from KV. Provisioned by environments/devtest/.
data "azurerm_key_vault_secret" "devtest_storage_key" {
  name         = "devtest-storage-account-key"
  key_vault_id = data.terraform_remote_state.secrets.outputs.key_vault_id
}

# Data source: Get image version from Azure Compute Gallery
data "azurerm_shared_image_version" "drupal" {
  name                = var.image_version
  image_name          = var.image_name
  gallery_name        = var.gallery_name
  resource_group_name = var.gallery_resource_group_name
}

# SAS token for Apache reverse proxy to serve blob storage files (read-only, 2-year expiry)
data "azurerm_storage_account_sas" "media_read" {
  connection_string = "DefaultEndpointsProtocol=https;AccountName=${var.devtest_storage_account};AccountKey=${data.azurerm_key_vault_secret.devtest_storage_key.value};EndpointSuffix=core.windows.net"
  https_only        = true
  start             = var.media_sas_start
  expiry            = var.media_sas_expiry

  resource_types {
    service   = false
    container = false
    object    = true
  }

  services {
    blob  = true
    queue = false
    table = false
    file  = false
  }

  permissions {
    read    = true
    write   = false
    delete  = false
    list    = false
    add     = false
    create  = false
    update  = false
    process = false
    tag     = false
    filter  = false
  }
}

# Resource group for dev resources.
#
# READ, not created -- same as the production and devtest stacks. The SP holds
# Contributor on five named groups and nothing wider, so it cannot create one.
#
# Never import it either. cleanup-dev runs an UNTARGETED `terraform destroy` on
# this stack after every promotion to main, so an imported group would be
# deleted -- and deleting it also deletes the SP's Contributor assignment scoped
# to it, which the SP cannot regrant itself. Dev would then be unrecoverable
# without PIM Owner re-running bootstrap. mccarthy-infra learned this on its
# first dev apply, 2026-08-10.
#
# Destroy still tears down everything inside the group, which is where the cost
# is; only the empty shell and its role assignment survive. bootstrap creates
# and owns the group.
data "azurerm_resource_group" "dev" {
  name = "${var.project_name}-dev-rg"
}

# Dev VM (validation stage)
module "dev_vm" {
  source = "../../modules/drupal-dev-vm"

  project_name         = var.project_name
  environment          = "dev"
  pr_number            = var.pr_number
  resource_group_name  = data.azurerm_resource_group.dev.name
  location             = var.location
  subnet_id            = var.subnet_id
  source_image_id      = data.azurerm_shared_image_version.drupal.id
  vm_size              = var.vm_size
  admin_username       = var.admin_username
  admin_ssh_public_key = var.admin_ssh_public_key
  assign_public_ip     = var.assign_public_ip

  # Pass database connection info via cloud-init (uses permanent devtest PostgreSQL)
  custom_data = templatefile("${path.module}/cloud-init.tftpl", {
    site_name               = var.project_name
    db_host                 = var.devtest_db_host
    db_name                 = var.db_name
    db_user                 = var.db_admin_username
    kv_name                 = data.terraform_remote_state.secrets.outputs.key_vault_name
    env_name                = "devtest"
    hash_salt_secret_name   = azurerm_key_vault_secret.drupal_hash_salt.name
    storage_account         = var.devtest_storage_account
    storage_key_secret_name = data.azurerm_key_vault_secret.devtest_storage_key.name
    # Escape % so mod_rewrite doesn't interpret %2B / %2F / %3D as backreferences (%N).
    # The escaped \% becomes a literal % in the substitution; combined with [NE] flag
    # in the RewriteRule and proxy-nocanon env, the SAS reaches Azure verbatim.
    storage_sas_token      = replace(data.azurerm_storage_account_sas.media_read.sas, "%", "\\%")
    anubis_key_secret_name = azurerm_key_vault_secret.anubis_signing_key.name
  })

  tags = {
    Environment  = "dev"
    PRNumber     = var.pr_number != null ? var.pr_number : "none"
    Project      = var.project_name
    Stage        = "dev-validation"
    ImageVersion = var.image_version
    CostCenter   = var.cost_center
  }
}
