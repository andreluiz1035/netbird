terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.100"
    }
  }
}

provider "azurerm" {
  features {}
}

# =========================
# RESOURCE GROUP
# =========================
resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.location
}

# =========================
# VNET
# =========================
resource "azurerm_virtual_network" "vnet" {
  name                = "vnet-netbird"
  address_space       = ["10.40.0.0/16"]
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
}

# =========================
# SUBNET
# =========================
resource "azurerm_subnet" "subnet" {
  name                 = "subnet-netbird"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.40.1.0/24"]
}

# =========================
# PUBLIC IPs
# =========================
resource "azurerm_public_ip" "pip_control" {
  name                = "pip-netbird-control"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  allocation_method = "Static"
  sku               = "Standard"
}

resource "azurerm_public_ip" "pip_data" {
  name                = "pip-netbird-data"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  allocation_method = "Static"
  sku               = "Standard"
}

# =========================
# PRIVATE DNS ZONE
# =========================
resource "azurerm_private_dns_zone" "dns" {
  name                = "netbird.internal"
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "dns_link" {
  name                  = "netbird-dns-link"
  resource_group_name   = azurerm_resource_group.rg.name
  private_dns_zone_name = azurerm_private_dns_zone.dns.name
  virtual_network_id    = azurerm_virtual_network.vnet.id
}

# =========================
# NSG (DATA PLANE)
# =========================
resource "azurerm_network_security_group" "nsg" {
  name                = "nsg-netbird"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  # SSH
  security_rule {
    name                       = "Allow-SSH"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  # STUN / TURN
  security_rule {
    name                       = "Allow-STUN-3478-UDP"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Udp"
    source_port_range          = "*"
    destination_port_range     = "3478"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Allow-TURN-UDP-Range"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Udp"
    source_port_range          = "*"
    destination_port_range     = "49152-65535"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Allow-TURN-TCP-443"
    priority                   = 130
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

# =========================
# NIC - CONTROL PLANE
# =========================
resource "azurerm_network_interface" "nic_control" {
  name                = "nic-netbird-control"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "ipconfig"
    subnet_id                     = azurerm_subnet.subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.pip_control.id
  }
}

# =========================
# NIC - DATA PLANE
# =========================
resource "azurerm_network_interface" "nic_data" {
  name                = "nic-netbird-data"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "ipconfig"
    subnet_id                     = azurerm_subnet.subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.pip_data.id
  }
}

# =========================
# NSG ASSOCIATIONS
# =========================
resource "azurerm_network_interface_security_group_association" "assoc_control" {
  network_interface_id      = azurerm_network_interface.nic_control.id
  network_security_group_id = azurerm_network_security_group.nsg.id
}

resource "azurerm_network_interface_security_group_association" "assoc_data" {
  network_interface_id      = azurerm_network_interface.nic_data.id
  network_security_group_id = azurerm_network_security_group.nsg.id
}

# =========================
# DNS RECORD - CONTROL PLANE
# =========================
resource "azurerm_private_dns_a_record" "cp" {
  name                = "cp"
  zone_name           = azurerm_private_dns_zone.dns.name
  resource_group_name = azurerm_resource_group.rg.name
  ttl                 = 300

  records = [
    azurerm_network_interface.nic_control.private_ip_address
  ]
}

# =========================
# DNS RECORD - DATA PLANE
# =========================
resource "azurerm_private_dns_a_record" "relay" {
  name                = "relay"
  zone_name           = azurerm_private_dns_zone.dns.name
  resource_group_name = azurerm_resource_group.rg.name
  ttl                 = 300

  records = [
    azurerm_network_interface.nic_data.private_ip_address
  ]
}

# =========================
# VM - CONTROL PLANE
# =========================
resource "azurerm_linux_virtual_machine" "control_plane" {
  name                = "vm-netbird-controlplane"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location

  size          = "Standard_B1s"
  computer_name = "netbirdcp"

  admin_username = var.admin_username
  admin_password = var.admin_password

  disable_password_authentication = false

  network_interface_ids = [
    azurerm_network_interface.nic_control.id
  ]

  os_disk {
    name                 = "osdisk-control"
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts"
    version   = "latest"
  }

  boot_diagnostics {}
  patch_mode = "ImageDefault"
}

# =========================
# VM - DATA PLANE
# =========================
resource "azurerm_linux_virtual_machine" "data_plane" {
  name                = "vm-netbird-dataplane"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location

  size          = "Standard_B1s"
  computer_name = "netbirddp"

  admin_username = var.admin_username
  admin_password = var.admin_password

  disable_password_authentication = false

  network_interface_ids = [
    azurerm_network_interface.nic_data.id
  ]

  os_disk {
    name                 = "osdisk-data"
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts"
    version   = "latest"
  }

  boot_diagnostics {}
  patch_mode = "ImageDefault"
}