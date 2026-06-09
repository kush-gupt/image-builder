# --- Azure identity (provider uses ARM_CLIENT_ID / ARM_CLIENT_SECRET / ARM_TENANT_ID env vars) ---

variable "subscription_id" {
  description = "Azure subscription ID. Falls back to ARM_SUBSCRIPTION_ID env var if unset."
  type        = string
  default     = null
}

# --- Resource group (must already exist) ---

variable "resource_group_name" {
  description = "Name of the pre-existing Azure resource group."
  type        = string
}

variable "location" {
  description = "Azure region for all resources."
  type        = string
  default     = "eastus"
}

# --- Storage ---

variable "storage_account_name" {
  description = "Storage account name. If empty, auto-derived from resource group name."
  type        = string
  default     = ""
}

variable "storage_container_name" {
  description = "Blob container for VHD uploads."
  type        = string
  default     = "vhds"
}

# --- VHD source ---

variable "vhd_dir" {
  description = "Local directory containing built VHD files."
  type        = string
  default     = "../output"
}

# --- Compute Gallery ---

variable "gallery_name" {
  description = "Azure Compute Gallery name."
  type        = string
  default     = "stig_images"
}

variable "image_version" {
  description = "Gallery image version to publish."
  type        = string
  default     = "1.0.0"
}

# --- Test VM deployment (Phase 3) ---

variable "deploy_test_vms" {
  description = "Set to true to deploy test VMs and run STIG verification."
  type        = bool
  default     = true
}

variable "vm_size" {
  description = "Azure VM size for test VMs."
  type        = string
  default     = "Standard_D2s_v6"
}

variable "admin_username" {
  description = "Admin username for test VMs."
  type        = string
  default     = "azureuser"
}

variable "output_dir" {
  description = "Local directory for STIG reports downloaded from test VMs."
  type        = string
  default     = "../output"
}
