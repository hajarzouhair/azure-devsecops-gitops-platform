# État stocké dans Azure Storage plutôt qu'en local :
# - survit si ta machine change/plante
# - verrouillage automatique (empêche deux `apply` simultanés)
# - condition nécessaire pour un vrai travail d'équipe ou en CI
terraform {
  backend "azurerm" {
    resource_group_name  = "rg-hajar-azure-project-tfstate"
    storage_account_name = "sttfhajarazuredev"
    container_name       = "tfstate"
    key                  = "terraform.tfstate"
  }
}
