# Connaissances projet pour l'agent d'investigation

## Architecture
- portfolio-app est une application Spring Boot exposée sur le namespace dev
- Les métriques sont exposées via Actuator sur /actuator/prometheus,
  contrôlé par la propriété management.endpoints.web.exposure.include
- Le HPA scale entre 1 et 4 replicas sur la base du CPU
- ArgoCD est en mode selfHeal:true — tout changement manuel via
  kubectl sur une ressource gérée par ArgoCD sera annulé automatiquement,
  sauf s'il est d'abord committé dans Git

## Erreurs connues et leur cause
- CreateContainerConfigError au démarrage : historiquement causé par un
  user non-numérique dans le Dockerfile, incompatible avec les policies
  Kyverno qui imposent runAsNonRoot avec un UID numérique
- Pod Pending qui ne se résorbe qu'en supprimant un autre pod : signe de
  saturation du node pool "system" — vérifier node_count dans
  terraform/aks.tf avant toute autre hypothèse
