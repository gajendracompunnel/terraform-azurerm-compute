module "publicVnet" {
  source              = "Azure/vnet/azurerm"
  version             = "4.1.0"
  resource_group_name = var.resource_group_name
  vnet_location       = var.location
  vnet_name           = var.vnet_name
  use_for_each        = true
  address_space       = var.vnet_address_space
  subnet_names        = var.subnet_names
  subnet_prefixes     = var.subnet_prefixes
}

data "azurerm_resource_group" "name" {
  name = var.resource_group_name
}

module "aks" {
  source                               = "Azure/aks/azurerm"
  version                              = "7.5.0"
  resource_group_name                  = var.resource_group_name
  private_cluster_enabled              = true
  cluster_name                         = var.aks_cluster_name
  location                             = var.location
  agents_availability_zones            = var.aks_agents_availability_zones
  role_based_access_control_enabled    = true
  rbac_aad                             = false
  vnet_subnet_id                       = module.publicVnet.vnet_subnets[0]
  network_policy                       = "azure"
  net_profile_dns_service_ip           = "10.0.32.10"
  net_profile_service_cidr             = "10.0.32.0/20"
  network_plugin                       = "azure"
  cluster_log_analytics_workspace_name = "temp-tbd"
  agents_min_count                     = 1
  agents_max_count                     = 2
  agents_count                         = null
  agents_pool_name                     = "custompool"
  agents_size                          = "Standard_B2s"
  enable_auto_scaling                  = true
  key_vault_secrets_provider_enabled   = true
  storage_profile_blob_driver_enabled  = true
  storage_profile_disk_driver_enabled  = true
  prefix                               = var.aks_prefix
  attached_acr_id_map                  = {
    acr = azurerm_container_registry.acr.id
  }
  depends_on = [
    azurerm_container_registry.acr
  ]
}


####################################################################
# Define a public IP for the jump server
resource "azurerm_public_ip" "jump_server_public_ip" {
  name                = "JumpServerPublicIP"
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Dynamic"
}
 
# Define a network interface for the jump server
resource "azurerm_network_interface" "jump_server_nic" {
  name                = "JumpServerNIC"
  location            = var.location
  resource_group_name = var.resource_group_name
 
  ip_configuration {
    name                          = "jump-server-ip-config"
    subnet_id                     = module.publicVnet.vnet_subnets[0]
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id           = azurerm_public_ip.jump_server_public_ip.id
  }
}
 
# Define the jump server virtual machine
resource "azurerm_virtual_machine" "jump_server" {
  name                  = "JumpServer"
  location              = var.location
  resource_group_name   = var.resource_group_name
  network_interface_ids = [azurerm_network_interface.jump_server_nic.id]
  vm_size               = "Standard_B1s"
  delete_os_disk_on_termination = true
 
  storage_os_disk {
    name              = "Jumpdisk"
    caching           = "ReadWrite"
    create_option     = "FromImage"
    managed_disk_type = "Premium_LRS"
  }
 
  storage_image_reference {
    publisher = "Canonical"
    offer     = "UbuntuServer"
    sku       = "18.04-LTS"
    version   = "latest"
  }
 
  os_profile {
    computer_name  = "JumpServer"
    admin_username = "jump"
  }
 
  os_profile_linux_config {
    disable_password_authentication = true
    ssh_keys {
      path     = "/home/jump/.ssh/authorized_keys"
      key_data = file("~/.ssh/id_rsa.pub")
    }
  }
}

####################################################################
resource "azurerm_container_registry" "acr" {
  name                          = var.acr_name
  location                      = var.location
  resource_group_name           = var.resource_group_name
  admin_enabled                 = true
  sku                           = "Premium"
  #admin_enabled                 = false
  public_network_access_enabled = var.public_network_access_enabled
}

resource "azurerm_private_dns_zone" "acr_private_dns_zone" {
  name                = "privatelink.azurecr.io"
  resource_group_name = var.resource_group_name
  depends_on          = [azurerm_container_registry.acr]
}

resource "azurerm_private_dns_zone_virtual_network_link" "acr_private_dns_zone_virtual_network_link" {
  name                  = "privateacrvineet-private-dns-zone-vnet-link"
  private_dns_zone_name = azurerm_private_dns_zone.acr_private_dns_zone.name
  resource_group_name   = var.resource_group_name
  virtual_network_id    = module.publicVnet.vnet_id
}

resource "azurerm_private_endpoint" "acr_private_endpoint" {
  name                = "privateacrvineet-private-endpoint"
  resource_group_name = var.resource_group_name
  location            = var.location
  subnet_id           = module.publicVnet.vnet_subnets[0]

  private_service_connection {
    name                           = "privateacrvineet-service-connection"
    private_connection_resource_id = azurerm_container_registry.acr.id
    is_manual_connection           = false
    subresource_names = [
      "registry"
    ]
  }

  private_dns_zone_group {
    name = "privateacrvineet-private-dns-zone-group"

    private_dns_zone_ids = [
      azurerm_private_dns_zone.acr_private_dns_zone.id
    ]
  }

  depends_on = [
    module.publicVnet,
    azurerm_container_registry.acr
  ]
}



######################################################################################
######################################################################################

data "azurerm_client_config" "current" {}

resource "azurerm_key_vault" "example" {
  name                       = var.key_vault_name
  location                   = var.location
  resource_group_name        = var.resource_group_name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
   sku_name                   = "standard"
  purge_protection_enabled    = false
  # enable_rbac_authorization   = true  
  public_network_access_enabled = false
}

resource "azurerm_private_endpoint" "pe_kv" {
  name                = var.private_endpoint_name
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = module.publicVnet.vnet_subnets[0]

  private_dns_zone_group {
    name                 = "privatednszonegroup"
    private_dns_zone_ids = [azurerm_private_dns_zone.main.id]
  }

  private_service_connection {
    name                           = "kvtestvinet"
    private_connection_resource_id = azurerm_key_vault.example.id
    is_manual_connection           = false
    subresource_names              = ["Vault"]
  }
}

resource "azurerm_private_dns_zone" "main" {
  name                = var.private_dns_zone_name
  resource_group_name = var.resource_group_name
}

resource "azurerm_private_dns_zone_virtual_network_link" "kv_private_dns_zone_virtual_network_link" {
  name                  = "privatekvvineet-private-dns-zone-vnet-link"
  private_dns_zone_name = azurerm_private_dns_zone.main.name
  resource_group_name   = var.resource_group_name
  virtual_network_id    = module.publicVnet.vnet_id
}

resource "azurerm_key_vault_access_policy" "example" {
  key_vault_id      = azurerm_key_vault.example.id
  tenant_id         = data.azurerm_client_config.current.tenant_id
  object_id         = module.aks.kubelet_identity[0].object_id
  key_permissions   = ["Get"]
  secret_permissions = ["Get"]
}

##############################################################################################
##############################################################################################


resource "azurerm_storage_account" "st" {
  name                     = "velocityst"
  resource_group_name      = var.resource_group_name
  location                 = var.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  min_tls_version = "TLS1_2"
  network_rules {
    default_action             = "Deny"
    ip_rules                   = []
  }
  public_network_access_enabled = false
}
# resource "azurerm_storage_container" "example" {
#   name                  = "containervinet"
#   storage_account_name  = azurerm_storage_account.st.name
#   container_access_type = "private"
# }
resource "azurerm_private_dns_zone" "pdns_st" {
  name                = "privatelink.blob.core.windows.net"
  resource_group_name = var.resource_group_name
}

resource "azurerm_private_endpoint" "pep_st" {
  name                = "pep-sd2488-st-non-prod-weu"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = module.publicVnet.vnet_subnets[0]

  private_service_connection {
    name                           = "sc-sta-velocity"
    private_connection_resource_id = azurerm_storage_account.st.id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "dns-group-sta"
    private_dns_zone_ids = [azurerm_private_dns_zone.pdns_st.id]
  }
}

resource "azurerm_private_dns_zone_virtual_network_link" "dns_vnet_lnk_sta" {
  name                  = "lnk-dns-velocity-sta"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.pdns_st.name
  virtual_network_id    = module.publicVnet.vnet_id
}

resource "azurerm_role_assignment" "assign_identity_storage_blob_data_contributor" {
  scope                = azurerm_storage_account.st.id
  role_definition_name = "Contributor"
  principal_id         = module.aks.kubelet_identity[0].object_id
}




###############################################################
###############################################################

OLD CODE

#############################################################
#############################################################

/*

variable "resource_group_name" {
  description = "The name of the resource group in which the resources will be created"
  default     = "terraform-compute"
}

variable "location" {
  description = "The location/region where the virtual network is created. Changing this forces a new resource to be created."
}

variable "vnet_subnet_id" {
  description = "The subnet id of the virtual network where the virtual machines will reside."
}

variable "security_group_id" {
  description = "The security group id to be associated with the network interface. Subnet-NSG-Association must be done outside this module"
}

variable "admin_password" {
  description = "The admin password to be used on the VMSS that will be deployed. The password must meet the complexity requirements of Azure"
  default     = ""
}

variable "ssh_key" {
  description = "Path to the public key to be used for ssh access to the VM.  Only used with non-Windows vms and can be left as-is even if using Windows vms. If specifying a path to a certification on a Windows machine to provision a linux vm use the / in the path versus backslash. e.g. c:/home/id_rsa.pub"
  default     = "~/.ssh/id_rsa.pub"
}

variable "remote_port" {
  description = "Remote tcp port to be used for access to the vms created via the nsg applied to the nics."
  default     = ""
}

variable "admin_username" {
  description = "The admin username of the VM that will be deployed"
  default     = "azureuser"
}

variable "custom_data" {
  description = "The custom data to supply to the machine. This can be used as a cloud-init for Linux systems."
  default     = ""
}

variable "storage_account_type" {
  description = "Defines the type of storage account to be created. Valid options are Standard_LRS, Standard_ZRS, Standard_GRS, Standard_RAGRS, Premium_LRS."
  default     = "Premium_LRS"
}

variable "vm_size" {
  description = "Specifies the size of the virtual machine."
  default     = "Standard_DS1_V2"
}

variable "nb_instances" {
  description = "Specify the number of vm instances"
  default     = "1"
}

variable "vm_hostname" {
  description = "local name of the VM"
  default     = "myvm"
}

variable "vm_os_simple" {
  description = "Specify UbuntuServer, WindowsServer, RHEL, openSUSE-Leap, CentOS, Debian, CoreOS and SLES to get the latest image version of the specified os.  Do not provide this value if a custom value is used for vm_os_publisher, vm_os_offer, and vm_os_sku."
  default     = ""
}

variable "vm_os_id" {
  description = "The resource ID of the image that you want to deploy if you are using a custom image.Note, need to provide is_windows_image = true for windows custom images."
  default     = ""
}

variable "is_windows_image" {
  description = "Boolean flag to notify when the custom image is windows based. Only used in conjunction with vm_os_id"
  default     = "false"
}

variable "vm_os_publisher" {
  description = "The name of the publisher of the image that you want to deploy. This is ignored when vm_os_id or vm_os_simple are provided."
  default     = ""
}

variable "vm_os_offer" {
  description = "The name of the offer of the image that you want to deploy. This is ignored when vm_os_id or vm_os_simple are provided."
  default     = ""
}

variable "vm_os_sku" {
  description = "The sku of the image that you want to deploy. This is ignored when vm_os_id or vm_os_simple are provided."
  default     = ""
}

variable "vm_os_version" {
  description = "The version of the image that you want to deploy. This is ignored when vm_os_id or vm_os_simple are provided."
  default     = "latest"
}

variable "tags" {
  type        = map(string)
  description = "A map of the tags to use on the resources that are deployed with this module."

  default = {
    source = "terraform"
  }
}

variable "allocation_method" {
  description = "Defines how an IP address is assigned. Options are Static or Dynamic."
  default     = "Dynamic"
}

variable "nb_public_ip" {
  description = "Number of public IPs to assign corresponding to one IP per vm. Set to 0 to not assign any public IP addresses."
  default     = "1"
}

variable "delete_os_disk_on_termination" {
  description = "Delete datadisk when machine is terminated"
  default     = "false"
}

variable "data_sa_type" {
  description = "Data Disk Storage Account type"
  default     = "Standard_LRS"
}

variable "data_disk_size_gb" {
  description = "Storage data disk size size"
  default     = ""
}

variable "data_disk" {
  type        = string
  description = "Set to true to add a datadisk."
  default     = "false"
}

variable "data_disk_caching" {
  type        = string
  description = "Specifies the caching requirements for this Data Disk. Possible values include None, ReadOnly and ReadWrite"
  default     = "ReadWrite"
}

variable "data_disk_acceleration" {
  type        = string
  description = "can only be enabled on Premium_LRS managed disks with no caching and M-Series VMs. Defaults to false"
  default     = "false"
}

variable "boot_diagnostics" {
  description = "(Optional) Enable or Disable boot diagnostics"
  default     = "false"
}

variable "boot_diagnostics_sa_type" {
  description = "(Optional) Storage account type for boot diagnostics"
  default     = "Standard_LRS"
}

variable "enable_accelerated_networking" {
  type        = string
  description = "(Optional) Enable accelerated networking on Network interface"
  default     = "false"
}

variable "domain_name_label" {
  description = "(Optional) an optional DNS name for the public ip"
  type        = string
  default     = ""
}

variable "domain_name_labels" {
  description = "(Optional) an optional list of DNS names for the public ip"
  type        = list
  default     = []
}


*/
