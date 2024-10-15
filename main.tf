# Generate a random integer to ensure unique resource names
resource "random_integer" "ri" {
  min = 10000
  max = 99999
}

data "azurerm_resource_group" "rg" {
  name = "AKS-POC"  # Replace with your resource group name
}

# Virtual Network
resource "azurerm_virtual_network" "vnet" {
  name                = "vnet-aks-cosmos"
  location            = "West US"
  resource_group_name = data.azurerm_resource_group.rg.name
  address_space       = ["10.0.0.0/16"]
}

# Subnet for Private Endpoint
resource "azurerm_subnet" "private_endpoint_subnet" {
  name                             = "private-endpoint-subnet"
  resource_group_name              = data.azurerm_resource_group.rg.name
  virtual_network_name             = azurerm_virtual_network.vnet.name
  address_prefixes                 = ["10.0.1.0/24"]
  enforce_private_link_service_network_policies = true
}

# AKS Cluster Subnet
resource "azurerm_subnet" "aks_subnet" {
  name                 = "aks-subnet"
  resource_group_name  = data.azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.2.0/24"]
}

# AKS Cluster
resource "azurerm_kubernetes_cluster" "aks" {
  name                = "aks-cluster-${random_integer.ri.result}"
  location            = "West US"
  resource_group_name = data.azurerm_resource_group.rg.name
  dns_prefix          = "aks-${random_integer.ri.result}"

  default_node_pool {
    name       = "default"
    node_count = 1
    vm_size    = "standard_b8pls_v2"
    vnet_subnet_id = azurerm_subnet.aks_subnet.id
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin = "azure"
    dns_service_ip = "10.0.3.10"  # Make sure this is in the aks_subnet range
    service_cidr   = "10.0.3.0/24"  # Ensure this does not overlap with existing subnets
  }

  depends_on = [azurerm_virtual_network.vnet]  # Ensure the vnet is created first
}

# Cosmos DB Account (MongoDB API)
resource "azurerm_cosmosdb_account" "cosmosdb" {
  name                = "cosmosdb-${random_integer.ri.result}"
  location            = "West US"
  resource_group_name = data.azurerm_resource_group.rg.name
  offer_type          = "Standard"
  kind                = "MongoDB"

  consistency_policy {
    consistency_level = "Session"
  }

  capabilities {
    name = "EnableMongo"
  }

  geo_location {
    location          = "West US"
    failover_priority = 0
  }
}

# Private Endpoint for Cosmos DB
resource "azurerm_private_endpoint" "private_endpoint" {
  name                = "cosmosdb-private-endpoint"
  location            = "West US"
  resource_group_name = data.azurerm_resource_group.rg.name
  subnet_id           = azurerm_subnet.private_endpoint_subnet.id

  private_service_connection {
    name                           = "cosmosdb-psc"
    private_connection_resource_id = azurerm_cosmosdb_account.cosmosdb.id
    subresource_names              = ["mongodb"]
    is_manual_connection           = false
  }

  depends_on = [
    azurerm_virtual_network.vnet, 
    azurerm_cosmosdb_account.cosmosdb,
    azurerm_subnet.private_endpoint_subnet  # Ensure subnet is created first
  ]
}

# Private DNS Zone for Cosmos DB
resource "azurerm_private_dns_zone" "private_dns" {
  name                = "privatelink.mongo.cosmos.azure.com"
  resource_group_name = data.azurerm_resource_group.rg.name
}

# DNS Zone Virtual Network Link
resource "azurerm_private_dns_zone_virtual_network_link" "dns_vnet_link" {
  name                  = "dns-link"
  resource_group_name   = data.azurerm_resource_group.rg.name
  private_dns_zone_name = azurerm_private_dns_zone.private_dns.name
  virtual_network_id    = azurerm_virtual_network.vnet.id
}

# Private DNS A Record for Cosmos DB
data "azurerm_network_interface" "private_endpoint_nic" {
  name                = azurerm_private_endpoint.private_endpoint.private_service_connection.name
  resource_group_name = data.azurerm_resource_group.rg.name
}

resource "azurerm_private_dns_a_record" "private_dns_record" {
  name                = azurerm_cosmosdb_account.cosmosdb.name
  zone_name           = azurerm_private_dns_zone.private_dns.name
  resource_group_name = data.azurerm_resource_group.rg.name
  ttl                 = 300

  records = [data.azurerm_network_interface.private_endpoint_nic.private_ip_address]
}

terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }

  required_version = ">= 1.0.0"
}

provider "azurerm" {
  features {}
}
