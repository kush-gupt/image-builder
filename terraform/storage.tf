resource "azurerm_storage_account" "vhds" {
  name                            = local.storage_account_name
  resource_group_name             = var.resource_group_name
  location                        = var.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  account_kind                    = "StorageV2"
  allow_nested_items_to_be_public = false
}

resource "azurerm_storage_container" "vhds" {
  name               = var.storage_container_name
  storage_account_id = azurerm_storage_account.vhds.id
}

# Re-runs when image_version changes. We skip filemd5() on multi-GB VHDs
# because it stalls terraform plan; azcopy --overwrite handles idempotency.
resource "null_resource" "vhd_upload" {
  for_each = local.images

  triggers = {
    image_version = var.image_version
    blob_name     = each.value.vhd_filename
  }

  provisioner "local-exec" {
    command     = "${path.module}/scripts/upload-vhd.sh"
    interpreter = ["bash"]
    environment = {
      STORAGE_ACCOUNT_NAME = azurerm_storage_account.vhds.name
      STORAGE_ACCOUNT_KEY  = azurerm_storage_account.vhds.primary_access_key
      CONTAINER_NAME       = azurerm_storage_container.vhds.name
      VHD_PATH             = "${var.vhd_dir}/${each.value.vhd_filename}"
      BLOB_NAME            = each.value.vhd_filename
    }
  }

  depends_on = [azurerm_storage_container.vhds]
}
