# --- SSH key for test VMs ---

resource "tls_private_key" "test" {
  count = var.deploy_test_vms ? 1 : 0

  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "local_sensitive_file" "ssh_private_key" {
  count = var.deploy_test_vms ? 1 : 0

  content         = tls_private_key.test[0].private_key_openssh
  filename        = "${path.module}/id_rsa_azure_test"
  file_permission = "0600"
}

resource "local_file" "ssh_public_key" {
  count = var.deploy_test_vms ? 1 : 0

  content         = tls_private_key.test[0].public_key_openssh
  filename        = "${path.module}/id_rsa_azure_test.pub"
  file_permission = "0644"
}

# --- Public IPs ---

resource "azurerm_public_ip" "test" {
  for_each = var.deploy_test_vms ? local.test_vms : {}

  name                = "${each.key}-pip"
  resource_group_name = var.resource_group_name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
}

# --- NICs ---

resource "azurerm_network_interface" "test" {
  for_each = var.deploy_test_vms ? local.test_vms : {}

  name                = "${each.key}-nic"
  resource_group_name = var.resource_group_name
  location            = var.location

  ip_configuration {
    name                          = "default"
    subnet_id                     = azurerm_subnet.test[0].id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.test[each.key].id
  }
}

# --- Test VMs ---

resource "azurerm_linux_virtual_machine" "test" {
  for_each = var.deploy_test_vms ? local.test_vms : {}

  name                = each.key
  resource_group_name = var.resource_group_name
  location            = var.location
  size                = var.vm_size
  admin_username      = var.admin_username

  network_interface_ids = [azurerm_network_interface.test[each.key].id]

  admin_ssh_key {
    username   = var.admin_username
    public_key = tls_private_key.test[0].public_key_openssh
  }

  source_image_id = azapi_resource.image_versions[each.value.image_key].id

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }

  depends_on = [azurerm_subnet_network_security_group_association.test]
}

# --- Wait for SSH then verify ---

resource "null_resource" "verify_vm" {
  for_each = var.deploy_test_vms ? local.test_vms : {}

  triggers = {
    vm_id = azurerm_linux_virtual_machine.test[each.key].id
  }

  provisioner "local-exec" {
    command     = "${path.module}/scripts/verify-vm.sh"
    interpreter = ["bash"]
    environment = {
      VM_NAME      = each.key
      VM_IP        = azurerm_public_ip.test[each.key].ip_address
      SSH_KEY      = local_sensitive_file.ssh_private_key[0].filename
      ADMIN_USER   = var.admin_username
      RHEL_VERSION = each.value.rhel_version
      OUTPUT_DIR   = var.output_dir
    }
  }

  depends_on = [azurerm_linux_virtual_machine.test]
}
