# --------------------------------------------------------------------------
# Node pool dédié à l'observabilité (Prometheus/Grafana/Alertmanager).
# Séparé du pool "system" qui héberge l'application, pour éviter que
# la stack de monitoring ne consomme des ressources au détriment de
# l'app (ou l'inverse) sur un cluster à capacité limitée.
# --------------------------------------------------------------------------
resource "azurerm_kubernetes_cluster_node_pool" "monitoring" {
  name                  = "monitoring"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.main.id
  vm_size               = "Standard_D2ads_v7" # même contrainte d'abonnement que le pool system
  node_count            = 1
  vnet_subnet_id        = azurerm_subnet.aks.id
  mode                  = "User" # "system" reste réservé aux composants critiques du cluster

  node_labels = {
    workload = "observability"
  }

  # Empêche tout pod normal (l'app, ArgoCD, etc.) d'être scheduled ici
  # par accident. Seuls les pods avec la toleration correspondante
  # (Prometheus/Grafana via leur values Helm) pourront y atterrir.
  node_taints = [
    "workload=observability:NoSchedule"
  ]

  tags = {
    project = var.project_name
  }
}
