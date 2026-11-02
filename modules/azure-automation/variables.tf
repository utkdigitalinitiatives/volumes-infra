variable "project_name" {
  description = "Project identifier used as the resource name prefix (e.g. volumes)"
  type        = string
}

variable "environment" {
  description = "Environment name (e.g., devtest)"
  type        = string
}

variable "resource_group_name" {
  description = "Name of the resource group"
  type        = string
}

variable "location" {
  description = "Azure region"
  type        = string
}

variable "target_tag_key" {
  description = "Tag key to filter PostgreSQL servers for auto-stop"
  type        = string
  default     = "AutoStop"
}

variable "target_tag_value" {
  description = "Tag value to filter PostgreSQL servers for auto-stop"
  type        = string
  default     = "true"
}

variable "schedule_timezone" {
  description = "Timezone for the automation schedule"
  type        = string
  default     = "America/New_York"
}

variable "schedule_week_days" {
  description = "Days of the week to run the schedule"
  type        = list(string)
  default     = ["Friday"]
}

# Azure rejects a start_time less than 5 minutes in the future, so a hardcoded
# date here is a time bomb: it works until it doesn't, and then every fresh
# bootstrap fails. It was "2026-02-13T22:00:00-05:00" and duly went off. Leave
# this null and main.tf anchors the first occurrence 10 days out at plan time.
# Set it explicitly only to pin a specific first run.
variable "schedule_start_time" {
  description = "First occurrence (RFC3339). Null anchors it 10 days out at plan time; recurrence is governed by schedule_week_days and schedule_timezone."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default     = {}
}
