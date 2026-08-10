output "resource_group_name" {
  description = "Nom du resource group créé"
  value       = azurerm_resource_group.main.name
}

output "vnet_name" {
  description = "Nom du réseau virtuel créé"
  value       = azurerm_virtual_network.main.name
}

output "aks_subnet_id" {
  description = "ID du sous-réseau réservé à AKS (utile pour l'étape suivante)"
  value       = azurerm_subnet.aks.id
}
