variable "project_name" {
  description = "Project identifier used as the resource name prefix"
  type        = string
  default     = "volumes"
}

variable "subscription_id" {
  description = "Azure subscription ID"
  type        = string
}

variable "location" {
  description = "Azure region for the Key Vault"
  type        = string
  default     = "eastus2"
}

variable "cost_center" {
  description = "CostCenter tag applied to every resource in this stack"
  type        = string
}

variable "gh_actions_sp_object_id" {
  description = <<-EOT
    Object ID (not Application/Client ID) of the <project>-github-actions service
    principal. Fetch with: az ad sp show --id <appId> --query id -o tsv
  EOT
  type        = string
}

variable "operator_object_ids" {
  description = "AAD object IDs of human operators that should have read/write access to all Key Vault secrets."
  type        = list(string)
  default     = []
}
