resource "azurerm_shared_image_gallery" "stig" {
  name                = var.gallery_name
  resource_group_name = var.resource_group_name
  location            = var.location
}

resource "azurerm_shared_image" "images" {
  for_each = local.images

  name                = each.key
  gallery_name        = azurerm_shared_image_gallery.stig.name
  resource_group_name = var.resource_group_name
  location            = var.location
  os_type             = "Linux"
  hyper_v_generation  = "V2"
  specialized         = false

  disk_controller_type_nvme_enabled = true

  identifier {
    publisher = "RedHat"
    offer     = each.value.offer
    sku       = each.value.sku
  }
}

resource "azurerm_shared_image_version" "images" {
  for_each = local.images

  name                = var.image_version
  gallery_name        = azurerm_shared_image_gallery.stig.name
  image_name          = azurerm_shared_image.images[each.key].name
  resource_group_name = var.resource_group_name
  location            = var.location

  blob_uri           = "${local.vhd_base_url}/${each.value.vhd_filename}"
  storage_account_id = azurerm_storage_account.vhds.id

  target_region {
    name                   = var.location
    regional_replica_count = 1
    storage_account_type   = "Standard_LRS"
  }

  timeouts {
    create = "60m"
  }

  depends_on = [null_resource.vhd_upload]
}
