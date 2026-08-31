# --------------------------------------------------------------------------
# Azure AI Foundry — infrastructure sous-jacente (compte + déploiement de
# modèle) provisionnée en Terraform. La création du Project et de l'Agent
# eux-mêmes se fait via le portail/CLI : le provider azurerm ne supporte
# pas encore pleinement cette partie sur le nouveau modèle "AI Foundry
# resource" (voir README, section AI Agent, pour le détail de ce choix).
# --------------------------------------------------------------------------

resource "azurerm_cognitive_account" "foundry" {
  name                = "aif-${var.project_name}-${var.environment}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  kind                = "AIServices"
  sku_name            = "S0"

  # Pas de clé API statique : seule l'authentification Azure AD
  # (identité managée / utilisateur RBAC) est acceptée. Même principe
  # que l'ACR (AcrPull via identité managée) et le Key Vault (RBAC).
  local_auth_enabled = false

  # Identité managée : le futur agent (ou un service qui l'appelle)
  # s'authentifiera sans clé statique, même pattern que le reste
  # du projet (ACR, Key Vault).
  identity {
    type = "SystemAssigned"
  }

  # Nécessaire pour activer l'Agent Service sur cette ressource.
  custom_subdomain_name      = "aif-${var.project_name}-${var.environment}"
  project_management_enabled = true

  tags = {
    project = var.project_name
  }
}

# --------------------------------------------------------------------------
# Déploiement du modèle — gpt-4o-mini : suffisant pour l'investigation
# d'incidents, nettement moins cher que gpt-4o, pas de coût horaire
# (facturation au token, contrairement aux nœuds AKS).
# --------------------------------------------------------------------------
resource "azurerm_cognitive_deployment" "agent_model" {
  name                 = "gpt-4.1-mini"
  cognitive_account_id = azurerm_cognitive_account.foundry.id

  model {
    format  = "OpenAI"
    name    = "gpt-4.1-mini"
    version = "2025-04-14"
  }

  sku {
    name     = "GlobalStandard"
    capacity = 10
  }

  lifecycle {
    ignore_changes = [model[0].version]
  }
}

output "foundry_endpoint" {
  value = azurerm_cognitive_account.foundry.endpoint
}


# --------------------------------------------------------------------------
# Autorise TOI (utilisatrice connectée en CLI) à utiliser le Project/Agent
# depuis le portail Foundry et pour les tests manuels.
# --------------------------------------------------------------------------
resource "azurerm_role_assignment" "current_user_ai_developer" {
  principal_id         = data.azurerm_client_config.current.object_id
  role_definition_name = "Azure AI Developer"
  scope                = azurerm_cognitive_account.foundry.id
}

# --------------------------------------------------------------------------
# Endpoint Foundry stocké dans le Key Vault existant — pas une donnée
# secrète en soi (pas de clé API, auth locale désactivée), mais on la
# centralise ici pour que n'importe quel service du projet (pipeline CI,
# futur tool MCP) la récupère au même endroit que les autres paramètres,
# plutôt que de la hardcoder.
# --------------------------------------------------------------------------
resource "azurerm_key_vault_secret" "foundry_endpoint" {
  name         = "foundry-endpoint"
  value        = azurerm_cognitive_account.foundry.endpoint
  key_vault_id = azurerm_key_vault.main.id

  depends_on = [azurerm_role_assignment.current_user_keyvault_admin]
}
