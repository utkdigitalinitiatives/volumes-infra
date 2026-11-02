# ------------------------------------------------------------------------------
# Networking Module
# ------------------------------------------------------------------------------
# Creates the virtual network infrastructure for the Drupal application:
#   - VNet with configurable address space
#   - Web subnet for VMSS/VM instances
#   - Private endpoints subnet for PostgreSQL and Blob Storage
#   - Network Security Groups with rules for HTTP/HTTPS, SSH, and health probes
#
# Security model:
#   - Supports Azure Front Door or direct Load Balancer access (toggle via variables)
#   - SSH access restricted to specific CIDR blocks
#   - Default deny rule for all other inbound traffic
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

# Virtual Network
resource "azurerm_virtual_network" "main" {
  name                = "${local.name_prefix}-vnet"
  address_space       = var.vnet_address_space
  location            = var.location
  resource_group_name = var.resource_group_name

  tags = local.common_tags
}

# Web Subnet (for VMSS Blue/Green)
resource "azurerm_subnet" "web" {
  name                 = "web-subnet"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.web_subnet_address_prefix]
}

# Private Endpoints Subnet (for PostgreSQL, Blob Storage)
resource "azurerm_subnet" "private_endpoints" {
  name                 = "private-endpoints-subnet"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.private_endpoints_subnet_address_prefix]

  # Required for private endpoints
  private_endpoint_network_policies = "Disabled"
}

# NSG for Web Subnet
resource "azurerm_network_security_group" "web" {
  name                = "${local.name_prefix}-web-nsg"
  location            = var.location
  resource_group_name = var.resource_group_name

  tags = local.common_tags
}

# NSG Rule: Allow HTTP from Azure Front Door
resource "azurerm_network_security_rule" "allow_http_front_door" {
  count = var.enable_front_door_rules ? 1 : 0

  name                        = "AllowHTTP-FrontDoor"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "80"
  source_address_prefix       = "AzureFrontDoor.Backend"
  destination_address_prefix  = "*"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.web.name
}

# NSG Rule: Allow HTTPS from Azure Front Door
resource "azurerm_network_security_rule" "allow_https_front_door" {
  count = var.enable_front_door_rules ? 1 : 0

  name                        = "AllowHTTPS-FrontDoor"
  priority                    = 110
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = "AzureFrontDoor.Backend"
  destination_address_prefix  = "*"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.web.name
}

# NSG Rule: Allow HTTP from Load Balancer / Internet (for PoC without Front Door)
resource "azurerm_network_security_rule" "allow_http_lb" {
  count = var.enable_load_balancer_rules ? 1 : 0

  name                        = "AllowHTTP-Internet"
  priority                    = 120
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "80"
  source_address_prefix       = "Internet"
  destination_address_prefix  = "*"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.web.name
}

# NSG Rule: Allow HTTPS from Load Balancer / Internet (for PoC without Front Door)
resource "azurerm_network_security_rule" "allow_https_lb" {
  count = var.enable_load_balancer_rules ? 1 : 0

  name                        = "AllowHTTPS-Internet"
  priority                    = 130
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = "Internet"
  destination_address_prefix  = "*"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.web.name
}

# NSG Rule: Allow Azure Load Balancer health probes
resource "azurerm_network_security_rule" "allow_lb_health_probes" {
  count = var.enable_load_balancer_rules ? 1 : 0

  name                        = "AllowAzureLoadBalancer"
  priority                    = 140
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "AzureLoadBalancer"
  destination_address_prefix  = "*"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.web.name
}

# NSG Rule: Allow SSH from specified CIDR blocks
resource "azurerm_network_security_rule" "allow_ssh" {
  count = length(var.allowed_ssh_cidr_blocks) > 0 ? 1 : 0

  name                        = "AllowSSH"
  priority                    = 200
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "22"
  source_address_prefixes     = var.allowed_ssh_cidr_blocks
  destination_address_prefix  = "*"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.web.name
}

# NSG Rule: Deny all other inbound traffic
resource "azurerm_network_security_rule" "deny_all_inbound" {
  name                        = "DenyAllInbound"
  priority                    = 4096
  direction                   = "Inbound"
  access                      = "Deny"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.web.name
}

# Associate NSG with Web Subnet
resource "azurerm_subnet_network_security_group_association" "web" {
  subnet_id                 = azurerm_subnet.web.id
  network_security_group_id = azurerm_network_security_group.web.id
}

# NSG for Private Endpoints Subnet (minimal rules - traffic via private endpoints)
resource "azurerm_network_security_group" "private_endpoints" {
  name                = "${local.name_prefix}-pe-nsg"
  location            = var.location
  resource_group_name = var.resource_group_name

  tags = local.common_tags
}

# Associate NSG with Private Endpoints Subnet
resource "azurerm_subnet_network_security_group_association" "private_endpoints" {
  subnet_id                 = azurerm_subnet.private_endpoints.id
  network_security_group_id = azurerm_network_security_group.private_endpoints.id
}
