# App Image - Rocky Linux 9
#
# Builds on top of the SHARED base image (drupal-base-rocky-linux-9) that
# lib-main-infra builds monthly, and adds only the Drupal codebase (from a
# tarball the workflow packs, see drupal_archive) and its Composer dependencies.
# Plugin requirements are in plugins.pkr.hcl.
#
# This repo intentionally contains no base-image template. The base is pure
# Rocky 9 + PHP/Apache/Composer with nothing site-specific in it, so duplicating
# the monthly build for a second site buys nothing. The tradeoff is that changes
# lib-main makes to the base land here on the next app build - pin
# BASE_IMAGE_VERSION if you need to hold a known-good base.
#
# Build time is roughly 20 minutes; the base build it skips is roughly 27.

source "azure-arm" "app" {
  # Authentication: ambient Azure CLI session (OIDC in CI, `az login` locally)
  use_azure_cli_auth = var.use_azure_cli_auth
  subscription_id    = var.subscription_id

  # Build VM configuration.
  # location and build_resource_group_name are mutually exclusive -- Packer takes
  # the location from an existing build resource group and rejects both together.
  location                  = var.build_resource_group_name == null ? var.location : null
  build_resource_group_name = var.build_resource_group_name
  vm_size                   = var.vm_size

  # Source image: shared base image from the Compute Gallery
  shared_image_gallery {
    subscription   = var.subscription_id
    resource_group = var.gallery_resource_group_name
    gallery_name   = var.gallery_name
    image_name     = var.base_image_name
    image_version  = var.base_image_version
  }

  # Plan info from the original Rocky Linux marketplace image. Azure requires
  # this even when building from a gallery image derived from the marketplace.
  # Marketplace terms are accepted per-subscription and were already accepted
  # for lib-main, so there is no marketplace-agreement bootstrap step here.
  plan_info {
    plan_name      = "9-base"
    plan_product   = "rockylinux-x86_64"
    plan_publisher = "resf"
  }

  # Output to the shared Compute Gallery under THIS project's image definition
  shared_image_gallery_destination {
    subscription         = var.subscription_id
    resource_group       = var.gallery_resource_group_name
    gallery_name         = var.gallery_name
    image_name           = var.image_name
    image_version        = var.image_version
    replication_regions  = var.replication_regions
    storage_account_type = "Standard_LRS"
  }

  # Managed image configuration (intermediate). Project-prefixed so it cannot
  # collide with lib-main's intermediate images in the shared resource group.
  managed_image_resource_group_name = var.gallery_resource_group_name
  managed_image_name                = "${var.site_name}-rocky9-${var.image_version}"

  # OS disk configuration
  os_type         = "Linux"
  os_disk_size_gb = var.os_disk_size_gb

  # Build VM networking
  virtual_network_name                = var.build_vnet_name
  virtual_network_subnet_name         = var.build_subnet_name
  virtual_network_resource_group_name = var.build_vnet_resource_group_name

  # SSH configuration
  communicator = "ssh"
  ssh_username = "packer"

  # Provenance recorded on the image so a running VM can be traced back to a commit
  azure_tags = {
    Application  = "drupal"
    Project      = var.site_name
    Builder      = "packer"
    Version      = var.image_version
    OS           = "rocky-linux-9"
    ImageType    = "app"
    BaseImageVer = var.base_image_version
    DrupalRepo   = var.drupal_archive != "" ? var.drupal_repo : "composer-create-project"
    DrupalRef    = var.drupal_ref
    DrupalSha    = var.drupal_sha
    BuildDate    = timestamp()
  }
}

build {
  name    = "volumes-rocky9"
  sources = ["source.azure-arm.app"]

  # Provisioner: Ansible (piped transfer avoids an SFTP dependency)
  provisioner "ansible" {
    playbook_file = "${path.root}/ansible/playbook.yml"
    user          = "packer"

    extra_arguments = [
      "--extra-vars", "ansible_become=true",
      "--extra-vars", "php_version=${var.php_version}",
      "--extra-vars", "drupal_env=production",
      "--extra-vars", "drupal_archive=${var.drupal_archive}",
      "--extra-vars", "anubis_version=${var.anubis_version}",
      "--extra-vars", "anubis_rpm_sha256=${var.anubis_rpm_sha256}"
    ]

    ansible_env_vars = [
      "ANSIBLE_HOST_KEY_CHECKING=False",
      "ANSIBLE_SSH_ARGS=-o ControlMaster=auto -o ControlPersist=60s",
      "ANSIBLE_SSH_TRANSFER_METHOD=piped"
    ]
  }

  # Provisioner: cleanup and generalize for Azure
  provisioner "shell" {
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E sh '{{ .Path }}'"
    inline = [
      # Clean package cache
      "dnf clean all",
      "rm -rf /var/cache/dnf/*",

      # Remove temporary files
      "rm -rf /tmp/*",
      "rm -rf /var/tmp/*",

      # Remove SSH host keys (regenerated on first boot)
      "rm -f /etc/ssh/ssh_host_*",

      # Clear logs
      "truncate -s 0 /var/log/*.log 2>/dev/null || true",
      "truncate -s 0 /var/log/**/*.log 2>/dev/null || true",
      "journalctl --vacuum-time=1s || true",

      # Clear machine-id (regenerated on first boot)
      "truncate -s 0 /etc/machine-id",

      # Clear bash history
      "rm -f /root/.bash_history",
      "rm -f /home/*/.bash_history 2>/dev/null || true",

      # Deprovision Azure agent
      "/usr/sbin/waagent -force -deprovision+user && export HISTSIZE=0 && sync"
    ]
  }
}
