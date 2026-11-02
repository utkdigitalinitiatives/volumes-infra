# ------------------------------------------------------------------------------
# Drupal VMSS Module
# ------------------------------------------------------------------------------
# Creates an Azure Linux Virtual Machine Scale Set for production Drupal:
#   - Rocky Linux 9 from Azure Compute Gallery (Packer-built images)
#   - Rolling upgrade policy for zero-downtime deployments
#   - Application health extension for load balancer integration
#   - Automatic instance repairs with configurable grace period
#   - Optional autoscaling based on CPU metrics
#   - System-assigned managed identity for Azure resource access
#
# Deployment:
#   Image updates trigger rolling upgrades (20% batch size).
#   Cloud-init configures database, storage, and Drupal settings.
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
  name_prefix = "${var.project_name}-${var.environment}"
  common_tags = merge(var.tags, {
    Environment = var.environment
    ManagedBy   = "terraform"
    Application = var.project_name
  })
}

# Linux Virtual Machine Scale Set for Drupal
resource "azurerm_linux_virtual_machine_scale_set" "drupal" {
  name                = "${local.name_prefix}-vmss"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = var.vm_size
  instances           = var.instance_count

  # Required when MaxSurge is enabled on the rolling upgrade policy: the surge
  # path creates a brand-new instance and deletes the old one once healthy, so
  # provisioning extra instances up front is incompatible (provider rejects the
  # apply otherwise). Steady-state stays at instance_count; a 2nd VM exists only
  # during a deploy.
  overprovision = false

  admin_username                  = var.admin_username
  disable_password_authentication = true

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.admin_ssh_public_key
  }

  # Custom image from Azure Compute Gallery (built with Packer)
  # If source_image_id is provided, use it; otherwise fall back to marketplace
  source_image_id = var.source_image_id

  # Fallback to Rocky Linux 9 marketplace image if no gallery image provided
  dynamic "source_image_reference" {
    for_each = var.source_image_id == null ? [1] : []
    content {
      publisher = "resf"
      offer     = "rockylinux-x86_64"
      sku       = "9-base"
      version   = "latest"
    }
  }

  # Plan block required for marketplace images AND gallery images built from marketplace
  dynamic "plan" {
    for_each = var.use_marketplace_plan ? [1] : []
    content {
      name      = "9-base"
      publisher = "resf"
      product   = "rockylinux-x86_64"
    }
  }

  os_disk {
    storage_account_type = var.os_disk_type
    caching              = "ReadWrite"
    disk_size_gb         = var.os_disk_size_gb
  }

  network_interface {
    name    = "${local.name_prefix}-nic"
    primary = true

    ip_configuration {
      name                                   = "internal"
      primary                                = true
      subnet_id                              = var.subnet_id
      load_balancer_backend_address_pool_ids = var.load_balancer_backend_pool_id != null ? [var.load_balancer_backend_pool_id] : null
      application_security_group_ids         = length(var.application_security_group_ids) > 0 ? var.application_security_group_ids : null
    }
  }

  # Health extension for load balancer health probes
  extension {
    name                       = "HealthExtension"
    publisher                  = "Microsoft.ManagedServices"
    type                       = "ApplicationHealthLinux"
    type_handler_version       = "1.0"
    auto_upgrade_minor_version = true

    settings = jsonencode({
      protocol    = "http"
      port        = var.health_probe_port
      requestPath = var.health_probe_path
    })
  }

  # Automatic OS upgrades with rolling upgrade policy
  upgrade_mode = "Rolling"

  rolling_upgrade_policy {
    # MaxSurge: upgrade stands up a new healthy instance before deleting the old
    # one, so a single-instance scale set has no empty-backend-pool window during
    # a deploy. Health gating is provided by the ApplicationHealthLinux extension
    # above. Requires overprovision = false (set on the resource).
    maximum_surge_instances_enabled         = true
    max_batch_instance_percent              = 20
    max_unhealthy_instance_percent          = 20
    max_unhealthy_upgraded_instance_percent = 5
    pause_time_between_batches              = "PT0S"
  }

  # Enable automatic instance repairs
  automatic_instance_repair {
    enabled      = true
    grace_period = "PT30M"
  }

  # Boot diagnostics with managed storage
  boot_diagnostics {}

  # Custom data for cloud-init (Ansible preparation, etc.)
  custom_data = var.custom_data != null ? base64encode(var.custom_data) : null

  # Identity for Azure resource access (e.g., Key Vault, Blob Storage)
  identity {
    type = "SystemAssigned"
  }

  tags = local.common_tags

  lifecycle {
    ignore_changes = [
      instances, # Managed by autoscaler
      # AzureMonitorLinuxAgent is injected out-of-band by Defender's
      # DeployIfNotExists auto-provisioning. Without this, every apply plans to
      # remove it and Defender re-adds it — a perpetual drift loop (and a brief
      # monitoring gap each cycle). Ignoring the extension set still lets TF
      # create HealthExtension on first apply but stops reconciling extension
      # drift afterward; HealthExtension config is stable (port 80 / /health).
      extension,
    ]
  }
}

# Autoscale settings
resource "azurerm_monitor_autoscale_setting" "drupal" {
  count = var.enable_autoscaling ? 1 : 0

  name                = "${local.name_prefix}-autoscale"
  resource_group_name = var.resource_group_name
  location            = var.location
  target_resource_id  = azurerm_linux_virtual_machine_scale_set.drupal.id

  profile {
    name = "default"

    capacity {
      default = var.instance_count
      minimum = var.min_instances
      maximum = var.max_instances
    }

    # Scale out rule - CPU
    rule {
      metric_trigger {
        metric_name        = "Percentage CPU"
        metric_resource_id = azurerm_linux_virtual_machine_scale_set.drupal.id
        time_grain         = "PT1M"
        statistic          = "Average"
        time_window        = "PT5M"
        time_aggregation   = "Average"
        operator           = "GreaterThan"
        threshold          = var.scale_out_cpu_threshold
      }

      scale_action {
        direction = "Increase"
        type      = "ChangeCount"
        value     = "1"
        cooldown  = "PT5M"
      }
    }

    # Scale in rule - CPU
    rule {
      metric_trigger {
        metric_name        = "Percentage CPU"
        metric_resource_id = azurerm_linux_virtual_machine_scale_set.drupal.id
        time_grain         = "PT1M"
        statistic          = "Average"
        time_window        = "PT5M"
        time_aggregation   = "Average"
        operator           = "LessThan"
        threshold          = var.scale_in_cpu_threshold
      }

      scale_action {
        direction = "Decrease"
        type      = "ChangeCount"
        value     = "1"
        cooldown  = "PT5M"
      }
    }
  }

  tags = local.common_tags
}
