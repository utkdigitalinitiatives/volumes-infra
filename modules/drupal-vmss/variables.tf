variable "project_name" {
  description = "Project identifier used as the resource name prefix (e.g. volumes)"
  type        = string
}

variable "environment" {
  description = "Environment name (e.g., production, staging)"
  type        = string
}

variable "source_image_id" {
  description = "ID of the custom image from Azure Compute Gallery (built with Packer). Set to null to use marketplace image."
  type        = string
  default     = null
}

variable "use_marketplace_plan" {
  description = "Include Rocky Linux marketplace plan info. Required for gallery images built from marketplace images."
  type        = bool
  default     = true
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
  description = "ID of the subnet where VMSS instances will be deployed"
  type        = string
}

variable "vm_size" {
  description = <<-EOT
    Size of the VM instances. Defaults to Standard_B2als_v2 (2 vCPU / 4 GiB
    burstable, AMD) rather than the Standard_B2s that lib-main runs: the Bs v1
    series is under Azure capacity-growth restrictions from 2026-07-31 and is
    scheduled for retirement 2028-07-31. Basv2 is unrestricted and marginally
    cheaper. Do NOT substitute B2pls_v2 / B2ps_v2 / B2pts_v2 -- those are the
    Bpsv2 Arm64 line and will not boot the x64 gallery images.
  EOT
  type        = string
  default     = "Standard_B2als_v2"
}

variable "instance_count" {
  description = "Number of VM instances in the scale set"
  type        = number
  default     = 2
}

variable "min_instances" {
  description = "Minimum number of instances for autoscaling"
  type        = number
  default     = 1
}

variable "max_instances" {
  description = "Maximum number of instances for autoscaling"
  type        = number
  default     = 10
}

variable "admin_username" {
  description = "Admin username for the VMs"
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
  default     = "Premium_LRS"
}

variable "health_probe_path" {
  description = "Path for the health probe endpoint"
  type        = string
  default     = "/health"
}

variable "health_probe_port" {
  description = "Port for the health probe"
  type        = number
  default     = 80
}

variable "enable_autoscaling" {
  description = "Enable autoscaling for the VMSS"
  type        = bool
  default     = true
}

variable "scale_out_cpu_threshold" {
  description = "CPU percentage threshold to trigger scale out"
  type        = number
  default     = 75
}

variable "scale_in_cpu_threshold" {
  description = "CPU percentage threshold to trigger scale in"
  type        = number
  default     = 25
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

variable "load_balancer_backend_pool_id" {
  description = "ID of the load balancer backend pool (optional, for Front Door integration)"
  type        = string
  default     = null
}

variable "application_security_group_ids" {
  description = "List of application security group IDs to associate with the VMSS"
  type        = list(string)
  default     = []
}
