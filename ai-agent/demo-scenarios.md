# Demo Scenarios — Kubernetes Incident Investigator

Ce document présente deux scénarios d'incidents volontairement provoqués afin de démontrer les capacités du **Kubernetes Incident Investigator**.

Les scénarios couvrent deux catégories complémentaires :

- **Scenario 1 — Readiness Probe Investigation** : investigation d'un incident Kubernetes runtime directement sur AKS.
- **Scenario 2 — Vulnerability Detection and Analysis** : analyse de findings de sécurité issus du pipeline CI/CD.

Dans les deux cas, l'Agent collecte des données à partir des outils disponibles, corrèle les éléments de preuve et produit un diagnostic structuré ainsi que des recommandations de remédiation.

> **Safety boundary:** l'Agent est configuré comme un outil d'investigation et de diagnostic. Il ne modifie pas le cluster, le code source ou la configuration du pipeline.

---

# Scenario 1 — Readiness Probe Investigation

## Setup

Un incident Kubernetes est volontairement provoqué en modifiant directement le Deployment `portfolio-app` dans le cluster AKS.

Cette modification est réalisée directement sur le cluster afin de simuler un incident runtime réel **sans modifier Git et sans déclencher un nouveau pipeline CI/CD**.

La readiness probe est volontairement configurée avec un endpoint incorrect :

```bash
kubectl patch deployment portfolio-app -n dev --type='json' -p='[
  {"op": "replace", "path": "/spec/template/spec/containers/0/readinessProbe/httpGet/path", "value": "/actuator/health/readyz"}
]'
```

L'application expose réellement :

```text
/actuator/health/readiness
```

alors que la probe recherche :

```text
/actuator/health/readyz
```

La différence critique est le **`z` final** dans `readyz`.

L'endpoint `/actuator/health/readyz` n'existe donc pas et la readiness probe échoue continuellement.

### Expected behavior

Le Pod reste :

```text
Running
```

mais n'est pas considéré comme :

```text
Ready
```

Kubernetes retire alors le Pod des endpoints du Service.

Le problème est particulièrement important dans ce scénario car l'application ne possède qu'un seul replica (j'ai diminué le nombre de replica à 1 à cause d'une limite de nombre de pods max = 30 que j'ai confronté dans le noeud système) : l'absence de Pod Ready entraîne donc une **indisponibilité complète du trafic applicatif**.

---

**Collecte et corrélation des preuves.**
L'Agent ne se limite pas à une seule source d'information. Il croise plusieurs sources indépendantes afin de construire son diagnostic.

Les appels effectués permettent notamment d'obtenir :

- la liste des Pods avec **`pods list`** ;
- les événements Kubernetes avec **`events_list`** ;
- la configuration du Deployment avec **`resources_get Deployment`** ;
- les logs de l'application avec **`pods_log`** ;
- les métriques Prometheus avec **`prometheus execute_query`**.

Cette corrélation de cinq sources permet de distinguer le **symptôme** de sa **cause réelle**.


## Réponse finale de l'Agent

![Réponse finale de l'Agent](./ai-agent/docs/images/response1.png)


### Correction

Restaurer la configuration correcte de la probe :

```text
/actuator/health/readiness
```

Puis vérifier :

```bash
kubectl get pods -n dev
kubectl get endpoints -n dev portfolio-app
```

Le Pod doit redevenir `Ready` et réapparaître dans les endpoints du Service.

---

# Scenario 2 — Vulnerability Detection and Analysis

## Setup

Le deuxième scénario simule un incident de sécurité détecté pendant le pipeline CI/CD.

Trivy analyse l'image et les dépendances de l'application et détecte plusieurs findings, dont trois vulnérabilités **CRITICAL** affectant la dépendance Apache Tomcat.

Dans un pipeline DevSecOps normal, ces findings doivent déclencher le **security gate** et empêcher la poursuite vers les étapes suivantes.

Pour permettre la démonstration de l'Agent et générer un rapport d'analyse exploitable, le comportement bloquant a temporairement été neutralisé avec :

```bash
  script:
    - trivy image --format json --output trivy-report.json --input image.tar
    - trivy image --exit-code 1 --severity HIGH,CRITICAL --input image.tar || true
    - echo "Trivy scan terminé"
```

Cette modification est **uniquement destinée à la démonstration**.

> **Important:** `|| true` neutralise le code de retour du scan et désactive ainsi le garde-fou qui devait normalement faire échouer le job. Cette configuration ne doit pas être conservée dans un pipeline de production.

Le scan produit notamment :

| Target | Type | Vulnerabilities | Secrets |
|---|---|---:|---:|
| `image.tar (alpine 3.24.1)` | alpine | 0 | - |
| `app/app.jar` | jar | 3 | - |

Les trois findings sont de sévérité **CRITICAL** :

```text
Total: 3
HIGH: 0
CRITICAL: 3
```

---

## Question posée à l'Agent

![Question posée à l'Agent](./ai-agent/docs/images/question2.png)

---

**Figure 5 — Findings produits par Trivy.**  
Le scan identifie trois vulnérabilités critiques dans :

```text
org.apache.tomcat.embed:tomcat-embed-core
```

Version installée :

```text
10.1.55
```

Vulnérabilités détectées :

| CVE | Severity | Description |
|---|---|---|
| `CVE-2026-65182` | CRITICAL | Security constraint bypass due to improper access control |
| `CVE-2026-65905` | CRITICAL | Authentication bypass via limited replay attack in DIGEST authenticator |
| `CVE-2026-68525` | CRITICAL | Unauthorized resource access via FORM authentication bypass |

Trivy indique notamment comme versions corrigées :

```text
10.1.58
11.0.25
9.0.121
```

pour les versions de branche correspondantes.

Le scan indique également qu'aucune vulnérabilité n'a été détectée dans la cible Alpine analysée :

```text
image.tar (alpine 3.24.1) → 0 vulnerabilities
```

---

## Analyse produite par l'Agent

### 1. Vulnérabilités CRITICAL

L'Agent identifie les trois CVE affectant `tomcat-embed-core:10.1.55`.

Le risque potentiel concerne notamment :

- le contournement de contrôles d'accès ;
- le contournement d'authentification ;
- l'accès non autorisé à des ressources protégées.

L'Agent recommande donc de traiter ces findings comme **bloquants avant une mise en production**.

### 2. Findings SAST

L'analyse identifie également un finding SAST de sévérité **Medium** :

```text
Allocation of resources without limits or throttling
```

Localisation :

```text
ci/ai_security_review.py:70
```

L'Agent l'interprète comme un risque potentiel de consommation excessive de ressources et de déni de service.

Il distingue correctement ce finding des vulnérabilités Tomcat : les deux problèmes sont liés au même contexte de sécurité global mais n'ont pas la même cause technique.

### 3. Analyse du SBOM

L'Agent examine également les composants présents dans l'image et relève notamment :

```text
Alpine 3.24.1
JDK 21.0.12
Jackson 2.21.4
gnutls 3.8.13
BusyBox 1.37
```

Il ne présente pas ces composants comme vulnérables lorsqu'aucun finding correspondant n'est fourni.

Il les utilise plutôt pour identifier des considérations de sécurité et de réduction de surface d'attaque.

### 4. Corrélation

L'Agent corrèle les différentes couches :

```text
CI/CD
  │
  ├── Trivy
  │     └── 3 CRITICAL Tomcat
  │
  ├── SAST
  │     └── resource limits / throttling
  │
  └── SBOM
        └── composition de l'image
```

Cette corrélation permet de produire une analyse plus complète qu'un simple listing des CVE.

---

## Réponse finale de l'Agent

![Réponse finale de l'Agent](./ai-agent/docs/images/response2.png)

**Rapport final généré par l'Agent.**

![Rapport final généré par l'Agent](./ai-agent/ai-security-report.md)
L'Agent structure sa réponse en plusieurs niveaux :

1. résumé exécutif ;
2. vulnérabilités CRITICAL ;
3. vulnérabilités HIGH ;
4. findings SAST ;
5. analyse du SBOM ;
6. corrélation des findings ;
7. risques principaux ;
8. actions de remédiation ;
9. recommandation de déploiement.

### Recommandation principale

L'Agent recommande de **ne pas déployer en production** tant que la dépendance Tomcat vulnérable n'est pas mise à niveau vers une version corrigée.

Il recommande notamment :

- mise à niveau de `tomcat-embed-core` ;
- vérification de la configuration d'authentification ;
- ajout de tests de régression sécurité ;
- remplacement des versions `SNAPSHOT` par des versions figées ;
- réduction de la surface d'attaque de l'image ;
- réactivation d'un security gate CI sur les findings critiques ;
- nouvelle exécution de Trivy et SAST après correction.

### Principe de non-intervention

L'Agent précise que ses actions sont des **suggestions uniquement** :

```text
Note: suggestions uniquement; aucune modification n’est effectuée.
```

Il ne modifie donc ni le code, ni le pipeline, ni l'image, ni l'infrastructure.

---

# Demo Summary

Les deux scénarios démontrent deux capacités différentes du Kubernetes Incident Investigator :

| Scenario | Domaine | Incident | Sources analysées | Résultat |
|---|---|---|---|---|
| 1 — Readiness Probe | Kubernetes Runtime | Probe HTTP incorrecte | Pods, Events, Deployment, Logs, Prometheus | Root cause + blast radius + fix |
| 2 — Vulnerabilities | DevSecOps / CI | Dépendance Tomcat vulnérable | Trivy, SAST, SBOM | Analyse des risques + remédiation |

### Scenario 1 — Runtime Investigation

L'Agent démontre sa capacité à :

- interroger directement le cluster ;
- croiser plusieurs sources indépendantes ;
- citer les preuves associées à chaque affirmation ;
- distinguer symptôme et root cause ;
- analyser le blast radius ;
- proposer plusieurs options de correction ;
- respecter le principe de non-intervention.

### Scenario 2 — Security Analysis

L'Agent démontre sa capacité à :

- analyser des résultats Trivy ;
- identifier les vulnérabilités critiques ;
- contextualiser leur impact ;
- corréler Trivy, SAST et SBOM ;
- hiérarchiser les risques ;
- proposer des actions de remédiation ;
- recommander le blocage d'un déploiement présentant des vulnérabilités critiques.

Ces deux démonstrations illustrent ainsi deux rôles complémentaires de l'Agent :

```text
                    Kubernetes Incident Investigator
                                  │
                 ┌────────────────┴────────────────┐
                 │                                 │
                 ▼                                 ▼
       Runtime Investigation               Security Analysis
                 │                                 │
        AKS / Kubernetes                     CI/CD / Trivy
                 │                                 │
       Pods / Events / Logs             CVE / SAST / SBOM
                 │                                 │
                 └──────────────┬──────────────────┘
                                ▼
                     Evidence-based diagnosis
                                │
                                ▼
                       Remediation guidance
```

L'Agent agit donc comme une **couche d'investigation et de corrélation** au-dessus des outils opérationnels et de sécurité déjà présents dans la plateforme DevSecOps.
