# Authentication
#
# Builds authenticate through the Azure CLI session that `azure/login`
# establishes from a GitHub OIDC token. There is deliberately no client_secret
# variable: this project has no static service principal secret to leak.
variable "use_azure_cli_auth" {
  description = "Use the ambient Azure CLI session (established by azure/login via OIDC in CI)"
  type        = bool
  default     = true
}

variable "subscription_id" {
  description = "Azure subscription ID"
  type        = string
}

# Gallery configuration
#
# The gallery itself lives in lib-main-infra's resource group and is shared.
# Only image_name below is owned by this project.
variable "gallery_resource_group_name" {
  description = "Resource group containing the shared Compute Gallery (owned by lib-main-infra)"
  type        = string
}

variable "gallery_name" {
  description = "Name of the shared Compute Gallery (owned by lib-main-infra)"
  type        = string
}

variable "image_name" {
  description = "Name of this project's app image definition in the shared gallery"
  type        = string
  default     = "volumes-rocky-linux-9"
}

variable "image_version" {
  description = "Version of the image to create (CI passes 0.0.{github.run_number})"
  type        = string
}

# Base image configuration (two-tier image strategy)
variable "base_image_name" {
  description = "Name of the shared base image definition. Built monthly by lib-main-infra's base-image-build.yml."
  type        = string
  default     = "drupal-base-rocky-linux-9"
}

variable "base_image_version" {
  description = <<-EOT
    Version of the base image to build on (e.g. 2026.07.0).

    Deliberately has no default. lib-main-infra defaults this to a hardcoded
    version that has long since gone stale; a wrong-but-present default builds
    silently on an ancient base. Callers must be explicit. The build workflow
    resolves the newest published version unless the BASE_IMAGE_VERSION repo
    variable pins one.
  EOT
  type        = string
}

variable "replication_regions" {
  description = "Regions to replicate the image to"
  type        = list(string)
  default     = ["eastus2"]
}

# Build VM configuration
variable "location" {
  description = "Azure region for the build VM"
  type        = string
  default     = "eastus2"
}

variable "vm_size" {
  description = "VM size for the build VM"
  type        = string
  default     = "Standard_D2s_v5"
}

variable "os_disk_size_gb" {
  description = "OS disk size in GB"
  type        = number
  default     = 64
}

# Build VM networking (optional - uses a Packer-managed temporary VNet if unset)
variable "build_resource_group_name" {
  description = <<-EOT
    Existing resource group to build the VM in. Leave null and Packer creates a
    throwaway pkr-Resource-Group-* instead, which needs resourceGroups/write at
    SUBSCRIPTION scope. This project's service principal holds Contributor on
    five named resource groups and nothing wider, by design, so CI must set this.
    Note that Packer reports the resulting AuthorizationFailed as "a resource
    group with that name already exists", which is not what happened.
  EOT
  type        = string
  default     = null
}

variable "build_vnet_name" {
  description = "VNet name for build VM (optional)"
  type        = string
  default     = null
}

variable "build_subnet_name" {
  description = "Subnet name for build VM (optional)"
  type        = string
  default     = null
}

variable "build_vnet_resource_group_name" {
  description = "Resource group for build VNet (optional)"
  type        = string
  default     = null
}

# Application configuration
variable "php_version" {
  description = "PHP version the base image provides. Informational only - the base image sets this."
  type        = string
  default     = "8.3"
}

# App repository integration
#
# The app repo (utkdigitalinitiatives/volumes) is PRIVATE, so the build VM does
# not clone it. The workflow checks it out on the runner with a read-only deploy
# key, packs the exact commit with `git archive`, and passes the tarball's path
# here; Ansible copies it to the build VM and unpacks it. No credential ever
# reaches the build VM, so none can be baked into the published image, and the
# image carries no .git directory or remote URL. See README.md > Contract.
#
# mccarthy-infra clones over HTTPS instead, which only works because its app
# repo is public.
variable "drupal_archive" {
  description = "Absolute path, on the machine running Packer, to a .tar.gz of the app repo at the commit being built. Empty builds vanilla Drupal via composer create-project (bootstrap builds only)."
  type        = string
  default     = ""
}

variable "drupal_repo" {
  description = "owner/name of the app repo. Provenance only: recorded as the DrupalRepo image tag. Never contains a credential."
  type        = string
  default     = ""
}

variable "drupal_ref" {
  description = "Branch the build came from (e.g. dev). Provenance only: recorded as the DrupalRef image tag."
  type        = string
  default     = "main"
}

variable "drupal_sha" {
  description = "Full commit SHA packed into drupal_archive. Provenance only: recorded as the DrupalSha image tag."
  type        = string
  default     = ""
}

variable "site_name" {
  description = "Project identifier, used for image naming and tagging"
  type        = string
  default     = "volumes"
}

# Anubis bot-protection proxy. The RPM comes from the GitHub release and is
# checked against this hash before install. To upgrade, change both together:
# the hash is the "digest" GitHub shows for anubis-<version>-1.x86_64.rpm.
variable "anubis_version" {
  description = "Anubis release to install (no leading v)"
  type        = string
  default     = "1.27.0"
}

variable "anubis_rpm_sha256" {
  description = "SHA256 of anubis-<anubis_version>-1.x86_64.rpm"
  type        = string
  default     = "d95db3c2e1c114cc604132bf5f4192d3ddd7622f35d4b4c006b5462cc0a13b8d"
}
