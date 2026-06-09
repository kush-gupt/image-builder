resource "azurerm_virtual_network" "test" {
  count = var.deploy_test_vms ? 1 : 0

  name                = "stig-test-vnet"
  resource_group_name = var.resource_group_name
  location            = var.location
  address_space       = ["10.0.0.0/16"]
}

resource "azurerm_subnet" "test" {
  count = var.deploy_test_vms ? 1 : 0

  name                 = "default"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.test[0].name
  address_prefixes     = ["10.0.1.0/24"]
}

resource "azurerm_network_security_group" "test" {
  count = var.deploy_test_vms ? 1 : 0

  name                = "stig-test-nsg"
  resource_group_name = var.resource_group_name
  location            = var.location
}

resource "azurerm_network_security_rule" "allow_ssh" {
  count = var.deploy_test_vms ? 1 : 0

  name                        = "AllowSSH"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "22"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.test[0].name
}

resource "azurerm_subnet_network_security_group_association" "test" {
  count = var.deploy_test_vms ? 1 : 0

  subnet_id                 = azurerm_subnet.test[0].id
  network_security_group_id = azurerm_network_security_group.test[0].id
}
