resource "azurerm_kubernetes_cluster" "main" {
  name                = "aks-${var.project_name}-${var.environment}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  dns_prefix = "${var.project_name}-${var.environment}"

  # Azure active cette fonctionnalité par défaut sur les nouveaux clusters
  # et refuse de la désactiver ensuite. On la déclare explicitement à
  # "true" pour que Terraform ne tente plus de la remettre à false.
  # Elle sera utile plus tard si on active Workload Identity (fédération
  # OIDC entre AKS et Azure AD, alternative moderne au CSI Key Vault).
  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  # AzureRM 5.x : provisioning explicite des node pools
  node_provisioning_profile {
    mode = "Manual"
  }

  default_node_pool {
    name           = "system"
    node_count     = 1
    vm_size        = "Standard_D2ads_v7"
    vnet_subnet_id = azurerm_subnet.aks.id
  }

  # Identité managée : AKS s'authentifie auprès des autres services Azure
  # (comme ACR) sans qu'on ait à gérer de mot de passe/secret nous-mêmes.
  identity {
    type = "SystemAssigned"
  }

  # Add-on managé : permet aux pods de monter des secrets Azure Key Vault
  # comme des volumes, sans jamais les stocker en clair dans les manifests
  # ou les variables du pipeline CI.
  key_vault_secrets_provider {
    secret_rotation_enabled = true
  }

  network_profile {
    network_plugin = "azure"
    service_cidr   = "10.20.0.0/24"
    dns_service_ip = "10.20.0.10"
  }

  tags = {
    project = var.project_name
  }
}

# --------------------------------------------------------------------------
# Autorise AKS à récupérer (pull) des images depuis notre ACR, sans
# compte admin ni mot de passe partagé — via son identité managée.
# --------------------------------------------------------------------------
resource "azurerm_role_assignment" "aks_acr_pull" {
  principal_id                     = azurerm_kubernetes_cluster.main.kubelet_identity[0].object_id
  role_definition_name             = "AcrPull"
  scope                            = azurerm_container_registry.main.id
  skip_service_principal_aad_check = true
}

