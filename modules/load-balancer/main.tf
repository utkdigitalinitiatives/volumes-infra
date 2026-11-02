# ------------------------------------------------------------------------------
# Load Balancer Module
# ------------------------------------------------------------------------------
# Creates an Azure Standard Load Balancer for the Drupal VMSS:
#   - Public IP with optional DNS label
#   - Backend pool for VMSS instances
#   - HTTP health probe (HTTPS optional)
#   - Load balancing rules for HTTP/HTTPS traffic
#   - Outbound rule for VMSS internet access (package updates, etc.)
#
# Usage:
#   Connect VMSS to this load balancer via load_balancer_backend_pool_id output.
#   SNAT is disabled on inbound rules - use outbound rule for egress.
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
  name_prefix   = "${var.project_name}-${var.environment}"
  actual_pip_id = var.public_ip_id != null ? var.public_ip_id : azurerm_public_ip.lb[0].id
  common_tags = merge(var.tags, {
    Environment = var.environment
    ManagedBy   = "terraform"
    Application = var.project_name
  })
}

# Public IP for the Load Balancer (skipped when using an existing public IP)
resource "azurerm_public_ip" "lb" {
  count = var.public_ip_id == null ? 1 : 0

  name                = "${local.name_prefix}-lb-pip"
  resource_group_name = var.resource_group_name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"

  # Optional: DNS label for easy access
  domain_name_label = var.dns_label != null ? var.dns_label : null

  tags = local.common_tags
}

# Standard Load Balancer
resource "azurerm_lb" "main" {
  name                = "${local.name_prefix}-lb"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = "Standard"

  frontend_ip_configuration {
    name                 = "PublicIPAddress"
    public_ip_address_id = local.actual_pip_id
  }

  tags = local.common_tags
}

# Backend Address Pool for VMSS
resource "azurerm_lb_backend_address_pool" "vmss" {
  name            = "vmss-backend-pool"
  loadbalancer_id = azurerm_lb.main.id
}

# Health Probe - HTTP
resource "azurerm_lb_probe" "http" {
  name                = "http-health-probe"
  loadbalancer_id     = azurerm_lb.main.id
  protocol            = "Http"
  port                = var.health_probe_port
  request_path        = var.health_probe_path
  interval_in_seconds = var.health_probe_interval
  number_of_probes    = var.health_probe_threshold
}

# Load Balancing Rule - HTTP
resource "azurerm_lb_rule" "http" {
  name                           = "http-rule"
  loadbalancer_id                = azurerm_lb.main.id
  protocol                       = "Tcp"
  frontend_port                  = 80
  backend_port                   = 80
  frontend_ip_configuration_name = "PublicIPAddress"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.vmss.id]
  probe_id                       = azurerm_lb_probe.http.id
  tcp_reset_enabled              = true
  idle_timeout_in_minutes        = var.idle_timeout_minutes

  # Disable outbound SNAT - recommended for production
  disable_outbound_snat = true
}

# Load Balancing Rule - HTTPS (optional)
resource "azurerm_lb_rule" "https" {
  count = var.enable_https ? 1 : 0

  name                           = "https-rule"
  loadbalancer_id                = azurerm_lb.main.id
  protocol                       = "Tcp"
  frontend_port                  = 443
  backend_port                   = 443
  frontend_ip_configuration_name = "PublicIPAddress"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.vmss.id]
  probe_id                       = azurerm_lb_probe.http.id
  tcp_reset_enabled              = true
  idle_timeout_in_minutes        = var.idle_timeout_minutes

  # Client-IP affinity. Anubis stores an issued challenge on the instance that
  # issued it, so the answer has to come back to that instance; the default
  # five-tuple hash can send each new connection elsewhere.
  load_distribution = "SourceIP"

  disable_outbound_snat = true
}

# Outbound Rule for VMSS instances to access internet (e.g., for package updates)
resource "azurerm_lb_outbound_rule" "vmss" {
  count = var.enable_outbound_rule ? 1 : 0

  name                    = "vmss-outbound-rule"
  loadbalancer_id         = azurerm_lb.main.id
  protocol                = "All"
  backend_address_pool_id = azurerm_lb_backend_address_pool.vmss.id

  frontend_ip_configuration {
    name = "PublicIPAddress"
  }
}
