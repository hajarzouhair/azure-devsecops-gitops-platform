variable "project_name" {
  description = "Préfixe utilisé pour nommer toutes les ressources"
  type        = string
  default     = "hajar-azure-project"
}

variable "location" {
  description = "Région Azure où déployer les ressources"
  type        = string
  default     = "francecentral"
}

variable "environment" {
  description = "Nom de l'environnement (dev, staging, prod)"
  type        = string
  default     = "dev"
}

variable "vnet_address_space" {
  description = "Plage d'adresses du réseau virtuel"
  type        = list(string)
  default     = ["10.10.0.0/16"]
}

variable "subnet_address_prefix" {
  description = "Plage d'adresses du sous-réseau pour AKS"
  type        = list(string)
  default     = ["10.10.1.0/24"]
}
