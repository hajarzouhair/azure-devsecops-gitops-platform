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

output "acr_login_server" {
  description = "URL du registre ACR (utilisée dans le pipeline GitLab CI pour push/pull)"
  value       = azurerm_container_registry.main.login_server
}

output "aks_cluster_name" {
  description = "Nom du cluster AKS (utilisé avec `az aks get-credentials`)"
  value       = azurerm_kubernetes_cluster.main.name
}

output "key_vault_name" {
  description = "Nom du Key Vault (utilisé dans le SecretProviderClass Kubernetes)"
  value       = azurerm_key_vault.main.name
}

output "portfolio_app_identity_client_id" {
  description = "Client ID de l'UAMI applicative — à référencer dans serviceaccount.yaml et secret-provider-class.yaml"
  value       = azurerm_user_assigned_identity.portfolio_app.client_id
}
