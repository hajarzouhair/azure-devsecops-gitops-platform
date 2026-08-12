data "azurerm_client_config" "current" {}

resource "azurerm_key_vault" "main" {
  name                = "kv-${substr(replace(var.project_name, "-", ""), 0, 15)}-${var.environment}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tenant_id           = data.azurerm_client_config.current.tenant_id

  sku_name = "standard"

  enable_rbac_authorization = true

  # Permet la restauration en cas de suppression accidentelle
  purge_protection_enabled = false
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
# Un secret de démonstration, pour valider que toute la chaîne fonctionne
# (Key Vault -> CSI driver -> pod). À remplacer par de vrais secrets
# applicatifs plus tard (ex: identifiants de base de données).
# --------------------------------------------------------------------------
resource "azurerm_key_vault_secret" "demo" {
  name         = "demo-secret"
  value        = "hello-from-key-vault"
  key_vault_id = azurerm_key_vault.main.id

  depends_on = [azurerm_role_assignment.current_user_keyvault_admin]
}
