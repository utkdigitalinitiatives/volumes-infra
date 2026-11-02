variable "project_name" {
  description = "Project identifier used as the resource name prefix (e.g. volumes)"
  type        = string
}

variable "environment" {
  description = "Environment name (e.g., dev, test, pr-123)"
  type        = string
}

variable "pr_number" {
  description = "Pull request number (used for ephemeral PR environments)"
  type        = string
  default     = null
}

variable "source_image_id" {
  description = "ID of the custom image from Azure Compute Gallery (optional, falls back to marketplace)"
  type        = string
  default     = null
}

variable "resource_group_name" {
  description = "Name of the resource group"
  type        = string
}

variable "location" {
  description = "Azure region for resources"
  type        = string
}

variable "subnet_id" {
  description = "ID of the subnet where the VM will be deployed"
  type        = string
}

variable "vm_size" {
  description = "Size of the VM instance"
  type        = string
  default     = "Standard_D2s_v5"
}

variable "admin_username" {
  description = "Admin username for the VM"
  type        = string
  default     = "drupaladmin"
}

variable "admin_ssh_public_key" {
  description = "SSH public key for admin access"
  type        = string
}

variable "os_disk_size_gb" {
  description = "Size of the OS disk in GB"
  type        = number
  default     = 64
}

variable "os_disk_type" {
  description = "Type of the OS disk (Standard_LRS, StandardSSD_LRS, Premium_LRS)"
  type        = string
  default     = "StandardSSD_LRS"
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}

variable "custom_data" {
  description = "Custom data script (cloud-init) for VM initialization"
  type        = string
  default     = null
}

variable "assign_public_ip" {
  description = "Assign a public IP address to the VM"
  type        = bool
  default     = false
}

variable "application_security_group_ids" {
  description = "List of application security group IDs to associate with the VM"
  type        = list(string)
  default     = []
}

variable "enable_boot_diagnostics" {
  description = "Enable boot diagnostics for the VM"
  type        = bool
  default     = true
}

variable "use_marketplace_plan" {
  description = "Include marketplace plan information (required for gallery images built from marketplace)"
  type        = bool
  default     = true
}
