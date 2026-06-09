resource "random_string" "storage_suffix" {
  length  = 6
  lower   = true
  upper   = false
  numeric = true
  special = false
}

locals {
  # Auto-derive storage account name with a random suffix to avoid Azure DNS
  # cache issues when a storage account is deleted and recreated.
  storage_account_name = (
    var.storage_account_name != ""
    ? var.storage_account_name
    : substr("stig${replace(lower(var.resource_group_name), "/[^a-z0-9]/", "")}${random_string.storage_suffix.result}", 0, 24)
  )

  images = {
    "rhel9-stig-fips" = {
      vhd_filename = "rhel9-azure-stig-fips.vhd"
      offer        = "RHEL"
      sku          = "9-stig-fips"
      rhel_version = "9"
    }
    "rhel10-stig-fips" = {
      vhd_filename = "rhel10-azure-stig-fips.vhd"
      offer        = "RHEL"
      sku          = "10-stig-fips"
      rhel_version = "10"
    }
  }

  test_vms = {
    "rhel9-stig-test" = {
      image_key    = "rhel9-stig-fips"
      rhel_version = "9"
    }
    "rhel10-stig-test" = {
      image_key    = "rhel10-stig-fips"
      rhel_version = "10"
    }
  }

  vhd_base_url = "https://${local.storage_account_name}.blob.core.windows.net/${var.storage_container_name}"
}
