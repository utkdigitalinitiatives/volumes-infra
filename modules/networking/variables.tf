variable "project_name" {
  description = "Project identifier used as the resource name prefix (e.g. volumes)"
  type        = string
}

variable "environment" {
  description = "Environment name (e.g., production, staging)"
  type        = string
}

variable "resource_group_name" {
  description = "Name of the resource group"
  type        = string
}

variable "location" {
  description = "Azure region for resources"
  type        = string
}

variable "vnet_address_space" {
  description = "Address space for the VNet"
  type        = list(string)
  default     = ["10.0.0.0/16"]
}

variable "web_subnet_address_prefix" {
  description = "Address prefix for the web subnet (VMSS Blue/Green)"
  type        = string
  default     = "10.0.1.0/24"
}

variable "private_endpoints_subnet_address_prefix" {
  description = "Address prefix for private endpoints subnet (PostgreSQL, Blob)"
  type        = string
  default     = "10.0.10.0/24"
}

variable "allowed_ssh_cidr_blocks" {
  description = "CIDR blocks allowed for SSH access (empty list disables SSH)"
  type        = list(string)
  default     = []
}

variable "enable_front_door_rules" {
  description = "Enable NSG rules for Azure Front Door service tag"
  type        = bool
  default     = true
}

variable "enable_load_balancer_rules" {
  description = "Enable NSG rules for Azure Load Balancer health probes and traffic (for PoC without Front Door)"
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
