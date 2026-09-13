data "azurerm_client_config" "current" {}

resource "azurerm_key_vault" "main" {
  name                = "kv-${substr(replace(var.project_name, "-", ""), 0, 15)}-${var.environment}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tenant_id           = data.azurerm_client_config.current.tenant_id

  sku_name = "standard"

  # AzureRM 5.x
  rbac_authorization_enabled = true

  # Permet la restauration en cas de suppression accidentelle
  purge_protection_enabled   = false
  soft_delete_retention_days = 7

  tags = {
    project = var.project_name
  }
}

# --------------------------------------------------------------------------
# Autorise l'identité du CSI Secrets Store (créée automatiquement par
# l'add-on key_vault_secrets_provider dans aks.tf) à LIRE les secrets.
# Principe du moindre privilège : lecture seule, pas d'écriture.
# --------------------------------------------------------------------------
resource "azurerm_role_assignment" "aks_keyvault_secrets_user" {
  principal_id         = azurerm_kubernetes_cluster.main.key_vault_secrets_provider[0].secret_identity[0].object_id
  role_definition_name = "Key Vault Secrets User"
  scope                = azurerm_key_vault.main.id
}

# --------------------------------------------------------------------------
# Autorise MOI (l'utilisatrice connectée en CLI) à créer/lire des secrets
# dans le Vault pour les tests manuels et la démo.
# --------------------------------------------------------------------------
resource "azurerm_role_assignment" "current_user_keyvault_admin" {
  principal_id         = data.azurerm_client_config.current.object_id
  role_definition_name = "Key Vault Administrator"
  scope                = azurerm_key_vault.main.id
}

# --------------------------------------------------------------------------
# Identité dédiée à l'application (Workload Identity), distincte de
# l'identité interne de l'add-on key_vault_secrets_provider ci-dessus.
# C'est CETTE identité que le pod utilise réellement pour lire ses secrets.
# --------------------------------------------------------------------------
resource "azurerm_user_assigned_identity" "portfolio_app" {
  name                = "id-${var.project_name}-app-${var.environment}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location

  tags = {
    project = var.project_name
  }
}

# --------------------------------------------------------------------------
# Autorisation RBAC : cette identité peut lire (get/list) les secrets du
# Key Vault, rien de plus. Principe du moindre privilège, comme pour
# l'identité de l'add-on ci-dessus.
# --------------------------------------------------------------------------
resource "azurerm_role_assignment" "portfolio_app_keyvault_secrets_user" {
  principal_id         = azurerm_user_assigned_identity.portfolio_app.principal_id
  role_definition_name = "Key Vault Secrets User"
  scope                = azurerm_key_vault.main.id
}

# --------------------------------------------------------------------------
# Federated Identity Credential : établit la relation de confiance entre
# l'OIDC issuer du cluster AKS et cette identité, pour EXACTEMENT le
# ServiceAccount Kubernetes portfolio-app-sa dans le namespace dev.
# Si le namespace ou le nom du ServiceAccount changent côté k8s, cette
# valeur doit être mise à jour ici aussi, sinon la fédération échoue
# silencieusement (aucune erreur, juste jamais authentifié).
# --------------------------------------------------------------------------
resource "azurerm_federated_identity_credential" "portfolio_app" {
  name                = "fic-${var.project_name}-app-${var.environment}"
  resource_group_name = azurerm_resource_group.main.name
  parent_id           = azurerm_user_assigned_identity.portfolio_app.id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = azurerm_kubernetes_cluster.main.oidc_issuer_url
  subject             = "system:serviceaccount:dev:portfolio-app-sa"
}
