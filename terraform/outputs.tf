# --- Storage ---

output "storage_account_name" {
  description = "Name of the storage account holding VHD blobs."
  value       = azurerm_storage_account.vhds.name
}

# --- Gallery ---

output "gallery_id" {
  description = "Resource ID of the Azure Compute Gallery."
  value       = azurerm_shared_image_gallery.stig.id
}

output "image_version_ids" {
  description = "Resource IDs of published gallery image versions."
  value       = { for k, v in azapi_resource.image_versions : k => v.id }
}

# --- Test VMs (only populated when deploy_test_vms = true) ---

output "test_vm_public_ips" {
  description = "Public IP addresses of test VMs."
  value       = { for k, v in azurerm_public_ip.test : k => v.ip_address }
}

output "ssh_commands" {
  description = "SSH commands to connect to test VMs."
  value = {
    for k, v in azurerm_public_ip.test :
    k => "ssh -i ${path.module}/id_rsa_azure_test ${var.admin_username}@${v.ip_address}"
  }
}
