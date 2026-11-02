variable "project_name" {
  description = "Project identifier used as the resource name prefix (e.g. volumes)"
  type        = string
}

variable "environment" {
  description = "Environment name (e.g., production, staging, poc)"
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

variable "dns_label" {
  description = "DNS label for the public IP (creates <label>.<region>.cloudapp.azure.com)"
  type        = string
  default     = null
}

variable "health_probe_path" {
  description = "Path for the health probe endpoint"
  type        = string
  default     = "/health"
}

variable "health_probe_port" {
  description = "Port for the HTTP health probe"
  type        = number
  default     = 80
}

variable "health_probe_interval" {
  description = "Interval in seconds between health probes"
  type        = number
  default     = 15
}

variable "health_probe_threshold" {
  description = "Number of consecutive probe failures before marking unhealthy"
  type        = number
  default     = 2
}

variable "idle_timeout_minutes" {
  description = "Idle timeout in minutes for load balancer connections"
  type        = number
  default     = 4
}

variable "enable_https" {
  description = "Enable HTTPS load balancing rule and probe (for TLS termination at VMSS)"
  type        = bool
  default     = false
}

variable "enable_outbound_rule" {
  description = "Enable outbound rule for VMSS instances to access internet"
  type        = bool
  default     = true
}

variable "public_ip_id" {
  description = "Existing Azure public IP resource ID. If null, a new public IP is created."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
