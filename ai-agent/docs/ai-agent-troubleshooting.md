# Troubleshooting — Agent IA (Knowledge Base, Infrastructure & CI/CD)

Ce document réunit l'ensemble des incidents réels rencontrés lors de la
construction de l'agent IA d'investigation d'incidents, dans leur ordre
chronologique de résolution. Il est volontairement séparé du README
d'architecture pour que les deux restent lisibles indépendamment.

Deux parties :
- **Partie 1** : Azure AI Search, Knowledge Base & Foundry
- **Partie 2** : Modèle, infrastructure réseau/cluster & pipeline CI/CD

---

# PARTIE 1 — Azure AI Search, Knowledge Base & Foundry

## 1. Terraform — région Azure non disponible

**Contexte** : provisionnement initial de l'infrastructure dans
`westeurope`.

**Symptôme** :
```text
RequestDisallowedByAzure:
The selected region is currently not accepting new customers.
```

**Diagnostic** : restriction Azure sur la région pour cet abonnement,
pas une erreur de syntaxe Terraform.

**Correction** : passage de `westeurope` à `francecentral`. Le
provisionnement a ensuite continué normalement.

---

## 2. Azure AI Search — authentification par clé refusée

**Symptôme** : `api-key: <key>` retournait `HTTP 401 Unauthorized`,
même après régénération de la clé.

**Diagnostic** : le service avait `disableLocalAuth: true` —
l'authentification par clé API était structurellement désactivée,
indépendamment de la validité de la clé.

**Correction** : authentification via un token Microsoft Entra ID :
```bash
TOKEN=$(az account get-access-token \
  --scope "https://search.azure.com/.default" \
  --query accessToken -o tsv)
```
Testé avec succès (`HTTP 200`) sur `/indexes`.

---

## 3. Azure AI Search — permissions du Search Service

**Contexte** : l'indexer devait accéder au Blob Storage et aux
capacités de traitement Azure AI.

**Correction** : attribution à l'identité managée du Search Service
(`4b062e98-41e2-47a2-aef2-c90f12d35de7`) des rôles
`Storage Blob Data Reader` (sur `stfhajarazuredev`) et
`Cognitive Services OpenAI User` (sur `aif-hajar-azure-project-dev`).

**Résultat** : indexation réussie — `status: success, processed: 1,
failed: 0`.

---

## 4. Knowledge Base — permission du projet Foundry

**Correction** : attribution du rôle `Search Index Data Reader` à
l'identité managée du projet Foundry
(`7995e511-da7d-4c9a-a2a6-6500468ef404`), scopé précisément sur la
ressource Azure AI Search.

**Vérification** :
```bash
az role assignment list --assignee-object-id "7995e511-..." \
  --scope "/subscriptions/.../searchServices/aif-hajar-azure-project-project-srch-6j0l" \
  --query "[].{Role:roleDefinitionName,PrincipalId:principalId}" -o table
```

---

## 5. Foundry Connection — mauvais type d'authentification initial

**Symptôme** : la connexion Foundry `kb-knowledgebase-qfyjx` utilisait
initialement `authType: CustomKeys`, incompatible avec
`disableLocalAuth = true` côté Azure AI Search.

**Correction** : reconfiguration en `authType: ProjectManagedIdentity`,
`audience: https://search.azure.com/`.

---

## 6. Knowledge Base MCP — HTTP 405 (faux positif)

**Test** : `GET` sur l'endpoint MCP de la Knowledge Base.

**Résultat** : `HTTP 405, Allow: POST`.

**Interprétation** : pas un problème d'authentification — l'endpoint
existe et fonctionne, il attend simplement une requête `POST`. Un
signe que l'infrastructure est correctement exposée, pas cassée.

---

## 7. Foundry Agent — rate limit sur le modèle

**Symptôme** :
```text
Your requests to gpt-4.1-mini for gpt-4.1-mini in francecentral
have exceeded rate limit.
```

**Diagnostic** : problème isolé au déploiement du modèle, sans lien
avec Azure AI Search, le Blob Storage, l'index, la Knowledge Base, le
RBAC ou le MCP — tous fonctionnels par ailleurs.

**Correction (à ce stade du diagnostic)** : bascule temporaire sur
`gpt-5` pour poursuivre la validation de la Knowledge Base.

> Note de cohérence avec la Partie 2 : le déploiement de production
> retenu pour l'agent reste `gpt-4.1-mini` (SKU `GlobalStandard`) — la
> bascule sur `gpt-5` a servi à isoler ce test précis de la Knowledge
> Base, pas à changer le modèle définitif du projet.

---

## 8-9. Validation finale et grounding

Deux tests ont confirmé le bon fonctionnement de la chaîne complète :
- Une question ouverte sur le contenu de la base a permis à l'agent de
  lister correctement les documents indexés.
- Une question ciblée sur l'incident région Azure (section 1
  ci-dessus) a été correctement retrouvée et restituée par l'agent
  depuis `troubleshooting.md` lui-même — preuve que le retrieval
  fonctionne réellement, pas seulement la connaissance générale du
  modèle.

---

# PARTIE 2 — Modèle, infrastructure réseau/cluster & CI/CD

## 10. Dépréciation du modèle en cours de projet

**Symptôme** : `terraform apply` a échoué deux fois de suite sur le
déploiement du modèle Foundry :
1. `SKU 'Standard' not supported in this region` pour `gpt-4o-mini`.
2. Après passage à `GlobalStandard` : `ServiceModelDeprecating`.

**Correction** : vérification en lecture seule avant nouvel essai :
```bash
az cognitiveservices model list -l francecentral \
  --query "[?model.name=='gpt-4.1-mini'].{version:model.version,skus:model.skus[].name}"
```
Migration vers `gpt-4.1-mini` (`GlobalStandard`, `2025-04-14`), avec
un bloc `lifecycle { ignore_changes = [model[0].version] }` pour
éviter de revivre ce blocage à chaque mise à niveau automatique
Microsoft.

---

## 11. Quota vCPU de l'abonnement Azure

**Symptôme** : `ErrCode_InsufficientVCPUQuota` lors de l'ajout d'un
nœud au node pool `system`.

**Diagnostic** : quota régional de 4 vCPU sur l'abonnement gratuit,
déjà entièrement consommé par les deux node pools existants.

**Décision** : pas de demande d'augmentation de quota (peu fiable sur
abonnement gratuit) — optimisation de la capacité existante à la
place (voir #12).

---

## 12. Plafond de 30 pods/nœud (Azure CNI)

**Symptôme** : pods bloqués `Pending` avec `Too many pods`, malgré des
`requests` CPU/mémoire explicites.

**Diagnostic** : plafond Azure CNI de 30 pods par nœud, presque atteint
par les composants système (CoreDNS, konnectivity, metrics-server, CSI
drivers, webhook Workload Identity, Kyverno, ArgoCD).

**Corrections** :
- Désactivation des composants ArgoCD non utilisés (`dex-server`,
  `notifications-controller`, `applicationset-controller`) via un
  fichier Kustomize versionné.
- `strategy.rollingUpdate.maxSurge: 0` sur `portfolio-app`.
- Composants de l'agent IA schedulés sur le node pool `monitoring`
  (moins chargé) plutôt que `system`.

---

## 13. SecretProviderClass — placeholder oublié, puis fausse piste

**Symptôme** : montage du secret Key Vault en échec avec une réponse
HTTP 400 inhabituelle (page d'erreur ASP.NET générique).

**Diagnostic** : le champ `objectName` contenait encore littéralement
le texte `<nom-du-secret-dans-keyvault>`, jamais remplacé.

**Fausse piste corrigée en cours de route** : une tentative de
résolution dynamique via `clientID: "${SERVICE_ACCOUNT_CLIENT_ID}"` a
échoué (`AADSTS700016`) — cette syntaxe n'est pas supportée par la
version du driver CSI installée ; il s'agit d'une feature request
encore ouverte côté upstream, pas d'une fonctionnalité livrée.

**Correction finale** : retour à la valeur littérale du `clientID`
(stable tant que l'identité managée n'est pas recréée).

---

## 14. Authentification ACR incohérente

**Symptôme** : `admin_enabled = false` en Terraform, mais le pipeline
utilisait `ACR_USERNAME`/`ACR_PASSWORD` avec `docker login`.

**Correction** : migration complète vers la fédération OIDC
GitLab → Azure AD — App Registration dédiée, Federated Identity
Credential scopée au dépôt/branche exact, rôle `AcrPush` scopé
uniquement à l'ACR, authentification via
`az login --federated-token` + `az acr login`. Zéro secret stocké.

---

## 15. Key Vault — Workload Identity incomplète

**Symptôme** : `oidc_issuer_enabled` actif sur AKS, mais
`workload_identity_enabled` absent ; `SecretProviderClass` avec des
valeurs héritées de l'ancienne infrastructure.

**Correction** : activation complète d'Entra Workload Identity —
ServiceAccount annoté avec le `clientID` de l'identité managée,
injection automatique d'un jeton fédéré par `azure-wi-webhook`,
échangé contre un vrai jeton d'accès Azure AD. Aucun secret stocké
dans le cluster.

---

## 16. Absence totale d'ingress controller

**Symptôme** : `kubectl get ingressclass` ne retournait rien.

**Correction** : installation d'NGINX Ingress Controller via Helm,
schedulé sur le node pool `monitoring`. Provisionne un Azure Load
Balancer avec un coût horaire à surveiller.

---

## 17. Kyverno bloquant les images `:latest`

**Symptôme** : `disallow-latest-tag` a rejeté les déploiements des
serveurs MCP.

**Diagnostic complémentaire** : un nom d'image était aussi incorrect
(`kubernetes-mcp-server` au lieu du vrai `kubernetes_mcp_server`, avec
underscore).

**Correction** : tags réels épinglés via `skopeo list-tags`, nom
d'image corrigé.

---

## 18. Serveur MCP Prometheus bloqué en mode stdio

**Symptôme** : pod terminé proprement (`Completed`, pas
`CrashLoopBackOff`) en boucle.

**Diagnostic** : mode de transport par défaut stdio ; la version
d'image épinglée (`1.0.4`) ne supportait pas encore les variables
d'environnement pour forcer le mode HTTP.

**Correction** : mise à jour vers une version supportant le transport
HTTP, vérifiée contre les tags réellement disponibles.

---

## 19. Probe de santé Azure Load Balancer incompatible avec nginx

**Symptôme** : trafic externe en timeout, accès interne via NodePort
fonctionnel.

**Diagnostic** : confirmé via les métriques `DipAvailability` du Load
Balancer (~20% de réussite des probes) — la probe interrogeait `/` en
HTTP, et nginx retourne `404` sur `/` par défaut sans règle Ingress
correspondante, ce qu'Azure ne considère pas comme "healthy".

**Correction** : probe redirigée vers `/healthz` via l'annotation
`service.beta.kubernetes.io/azure-load-balancer-health-probe-request-path`.

---

## 20. Certificat TLS non associé — faute de frappe sur le hostname

**Symptôme** : le handshake TLS continuait de servir le certificat
auto-signé par défaut de nginx, malgré un certificat Let's Encrypt
valide déjà émis.

**Diagnostic** : une édition manuelle avait introduit un caractère
différent entre `spec.rules[].host` et `spec.tls[].hosts` (un point
remplacé par un tiret) — nginx associe les certificats par SNI exact.

**Correction**, diagnostiquée avec :
```bash
openssl s_client -connect <ip>:443 -servername <host-attendu> </dev/null \
  | openssl x509 -noout -issuer
```
Correction de l'incohérence entre les deux champs.

---

## 21. Pod solver cert-manager bloqué Pending

**Symptôme** : le challenge HTTP-01 n'aboutissait jamais,
`cm-acme-http-solver-*` restait `Pending`.

**Diagnostic** : même plafond de 30 pods/nœud que l'incident #12.

**Correction** : `nodeSelector`/`toleration` vers `monitoring` ajouté
directement dans `solvers[].http01.ingress.podTemplate` du
`ClusterIssuer`.

---

## 22. Job `ai_security_review` — quatre échecs successifs

1. **Erreur d'indentation YAML** dans `.gitlab-ci.yml`
   (`artifacts.paths` mal aligné) — blocage sans lien avec la logique
   IA elle-même.
2. **Mauvais jeton d'authentification** — le jeton OIDC brut de GitLab
   était envoyé directement comme `Bearer token` à Foundry ; ce jeton
   ne sert qu'à prouver l'identité pour un échange fédéré, pas comme
   jeton d'accès direct. Corrigé par un échange explicite
   `client_credentials` + `client_assertion` contre
   `login.microsoftonline.com` avant l'appel à Foundry.
3. **Dérive de version d'API** — `2025-05-01` rejetée
   (`UnsupportedApiVersion`) sur l'endpoint
   `/agents/{name}/endpoint/protocols/openai/responses` ; la bonne
   valeur, confirmée par l'exemple officiel Microsoft pour cet
   endpoint précis, est `api-version=v1`.
4. **`context_length_exceeded`** — les rapports Trivy/SAST/SBOM
   étaient envoyés bruts, dépassant le contexte du modèle. Corrigé en
   résumant chaque rapport (Trivy filtré sur HIGH/CRITICAL, SAST/SBOM
   tronqués aux champs essentiels) avant envoi.

Une fois ces quatre points corrigés, le pipeline a analysé un vrai
résultat : trois CVE **CRITICAL** sur
`org.apache.tomcat.embed:tomcat-embed-core 10.1.55`
(`CVE-2026-65182`, `CVE-2026-65905`, `CVE-2026-68525`, corrigées en
`10.1.58`), transformées automatiquement en rapport structuré et
priorisé.

---

## 23. Trous RBAC découverts en conditions réelles

Trois permissions en lecture seule manquantes, découvertes uniquement
lorsque l'agent en avait réellement besoin en cours d'investigation :
`namespaces` (liste cluster), `pods.metrics.k8s.io` (métriques live),
`endpoints` (vérification du routage Service pendant l'investigation
d'une probe readiness cassée).

**Correction** : consolidation en un `Role`/`ClusterRole` unique,
plus large mais toujours strictement en lecture seule, couvrant la
surface courante d'un diagnostic Kubernetes — pour éviter de revivre
cette découverte incrémentale en pleine démonstration.

---

## 24. Dashboard Grafana perdu à chaque redémarrage/reconstruction

**Symptôme** : le dashboard Grafana devait être réimporté manuellement
après chaque redémarrage du pod Grafana ou reconstruction du cluster.

**Diagnostic** : un dashboard importé via l'UI Grafana est stocké dans
la base interne du pod (SQLite par défaut) — non versionné, non
persistant au-delà du cycle de vie du pod.

**Correction** : dashboard défini comme code, via un `ConfigMap`
labellisé `grafana_dashboard: "1"` (`grafana-dashboard-configmap.yaml`,
versionné dans Git), automatiquement chargé par le sidecar Grafana du
chart `kube-prometheus-stack`. Le dashboard — y compris les nouveaux
panels spécifiques à l'agent — survit désormais à n'importe quel
`terraform destroy`/`apply`, confirmé après test.

---

## 25. Job `ai_security_review` jamais exécuté — dépendances en chaîne

**Symptôme** : aucune métrique d'agent nulle part, sans aucune erreur
visible.

**Diagnostic** : le job `push_to_acr` avait échoué (timeout réseau
ponctuel sur `az acr login`) ; via les `needs` en chaîne
(`sign_and_sbom` → `push_to_acr`, `ai_security_review` →
`sign_and_sbom`), GitLab n'exécute jamais un job dont une dépendance a
échoué. `ai_security_review` apparaissait donc en gris ("skipped")
dans le pipeline, jamais lancé — pas un bug du script.

**Correction** : relance simple du job en échec (`push_to_acr`) a
suffi ; le reste de la chaîne s'est exécuté normalement à la suite.

---

## 26. Push de métriques silencieusement inopérant

**Symptôme** : le job `ai_security_review` réussissait
(`STATUS: 200`, `Rapport généré avec succès`), mais aucune métrique
n'apparaissait jamais dans le Pushgateway.

**Diagnostic** : la fonction `push_metrics` ne loggait rien en cas de
variables d'environnement absentes (`return` silencieux) ni en cas de
succès réel — un job pouvait donc réussir sans que le push ait
réellement eu lieu, sans aucune trace pour le distinguer.

**Correction** : ajout de logs explicites (`PUSH METRICS STATUS: ...`)
à chaque branche de la fonction, succès comme échec — plus jamais de
zone d'ombre silencieuse sur cette étape.

---

## 27. Mot de passe Basic Auth désynchronisé après rotation

**Symptôme** : après régénération du mot de passe Basic Auth de
l'Ingress, `curl` externe vers le Pushgateway retournait `401
Unauthorized`, alors que l'accès interne (`port-forward`)
fonctionnait toujours.

**Diagnostic** : ce mot de passe est utilisé à quatre endroits
distincts qui doivent rester synchronisés — le secret Kubernetes
`mcp-basic-auth`, la variable GitLab `PUSHGATEWAY_AUTH`, et le header
`Authorization` configuré séparément sur **chacun** des deux tools MCP
dans le portail Foundry (`kubernetes-cluster` et
`prometheus-metrics`). La rotation n'avait été appliquée qu'à certains
de ces quatre endroits.

**Correction** : régénération complète et propagation à tous les
endroits concernés, vérifiée avec :
```bash
htpasswd -vb <(kubectl get secret mcp-basic-auth -n ai-agent -o jsonpath='{.data.auth}' | base64 -d) mcp-agent "<mot-de-passe>"
```

**Effet de bord repéré ensuite** : une fois le Pushgateway resynchronisé,
l'agent lui-même a échoué avec `401 Unauthorized` sur son propre tool
MCP Kubernetes — même cause, header `Authorization` du tool Foundry
resté sur l'ancien mot de passe. Mis à jour dans le portail pour les
deux tools.

**Limite assumée, à noter en roadmap** : cette Basic Auth partagée
statique sur 4 emplacements n'a aucune rotation automatisée — un
identifiant par consommateur (ou un vault de rotation géré) serait la
vraie amélioration, pas juste "faire attention" à chaque rotation
manuelle future.

---

# État final consolidé

| Composant | État |
|---|---|
| Blob Storage / Data Source / Indexer / Index (365 documents) | ✅ |
| Knowledge Base + connexion MCP (ProjectManagedIdentity) | ✅ |
| Agent Foundry (`gpt-4.1-mini`, GlobalStandard) | ✅ |
| Serveurs MCP Kubernetes & Prometheus (RBAC read-only) | ✅ |
| Ingress + TLS Let's Encrypt (production) | ✅ |
| Authentification ACR (OIDC, zéro secret) | ✅ |
| Key Vault (Workload Identity) | ✅ |
| Job CI `ai_security_review` (identité dédiée, résumé des rapports) | ✅ |
| Observabilité de l'agent (Pushgateway → Prometheus → Grafana) | ✅ |
| Dashboard Grafana persistant (ConfigMap as code) | ✅ |
| Scénario de démo readiness probe (investigation multi-sources) | ✅ |

---

# Leçons apprises

1. **Une erreur Terraform peut venir d'une restriction Azure**, pas
   forcément d'une faute de configuration — vérifier région, quotas et
   policies avant de chercher un bug de syntaxe.
2. **`disableLocalAuth=true` impose une architecture Entra ID/RBAC**
   de bout en bout — les clés API cessent d'être une option, pas
   seulement une mauvaise pratique.
3. **Vérifier le `principalId` exact**, pas seulement un nom de
   ressource, avant d'attribuer un rôle RBAC — deux identités
   managées différentes (Search vs Foundry Project) sont faciles à
   confondre.
4. **Un code HTTP inattendu n'est pas toujours un échec** — un `405`
   sur un endpoint MCP, ou un timeout de probe, peuvent signaler une
   infrastructure qui fonctionne mais qu'on interroge mal.
5. **Séparer les couches de diagnostic** : un rate limit sur le
   modèle, un quota vCPU sur l'abonnement, et un plafond de pods par
   nœud sont trois limites Azure complètement indépendantes qui
   produisent des symptômes superficiellement similaires
   ("ça ne marche pas") — isoler la couche avant de corriger évite de
   changer la mauvaise chose.
6. **Ne jamais faire confiance à une syntaxe non vérifiée**, même
   documentée par ailleurs — la tentative `${SERVICE_ACCOUNT_CLIENT_ID}`
   (#13) et les versions d'API Foundry qui ont changé deux fois (#22)
   montrent qu'une vérification en lecture seule avant application
   coûte moins cher qu'un aller-retour d'échec en production.
7. **Un job CI qui réussit ne prouve pas que chaque étape interne a
   réellement fonctionné** (#26) — un `return` silencieux en cas
   d'échec partiel peut masquer un problème pendant plusieurs runs.
   Logger explicitement chaque branche critique, succès inclus, pas
   seulement les erreurs.
8. **Un secret partagé entre plusieurs consommateurs est un risque de
   désynchronisation, pas une simplification** (#27) — chaque
   rotation doit être propagée partout où le secret est utilisé, ou
   remplacée par un identifiant dédié par consommateur dès que c'est
   raisonnable.

