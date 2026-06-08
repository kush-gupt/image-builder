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

# azapi instead of azurerm: image definitions can 404 briefly after creation
# due to Azure propagation delay. The retry block handles it without time_sleep.
resource "azapi_resource" "image_versions" {
  for_each = local.images

  type      = "Microsoft.Compute/galleries/images/versions@2024-03-03"
  name      = var.image_version
  parent_id = azurerm_shared_image.images[each.key].id
  location  = var.location

  body = {
    properties = {
      storageProfile = {
        osDiskImage = {
          source = {
            uri              = "${local.vhd_base_url}/${each.value.vhd_filename}"
            storageAccountId = azurerm_storage_account.vhds.id
          }
        }
      }
      publishingProfile = {
        targetRegions = [
          {
            name                 = var.location
            regionalReplicaCount = 1
            storageAccountType   = "Standard_LRS"
          }
        ]
      }
    }
  }

  retry = {
    error_message_regex  = ["ParentResourceNotFound", "NotFound", "source blob.*not accessible"]
    interval_seconds     = 5
    max_interval_seconds = 30
  }

  timeouts {
    create = "30m"
  }

  depends_on = [null_resource.vhd_upload]
}
