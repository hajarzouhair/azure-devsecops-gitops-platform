# Secure Cloud Platform on Azure — GitOps, DevSecOps & Observability

A production-style Kubernetes platform built on Azure (AKS), designed around a **security-by-design** and **GitOps-first** philosophy rather than bolted-on tooling. This project covers the full lifecycle of a cloud-native application: infrastructure provisioning, secure CI/CD, continuous deployment, runtime security enforcement, autoscaling, and real-time observability with alerting.

> This repository is mirrored to GitHub for visibility. The active CI/CD pipeline (GitLab CI) and GitOps deployment (ArgoCD) run against the source repo on GitLab — this mirror is a snapshot of the code and documentation, not a second live deployment.

> Real debugging log for this project (issues encountered, root causes, fixes): [`docs/troubleshooting.md`](./docs/troubleshooting.md)

---

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [Tech Stack](#tech-stack)
- [1. Infrastructure as Code (Terraform)](#1-infrastructure-as-code-terraform)
- [2. Secure CI/CD Pipeline](#2-secure-cicd-pipeline)
- [3. GitOps with ArgoCD](#3-gitops-with-argocd)
- [4. Runtime Security (Defense in Depth)](#4-runtime-security-defense-in-depth)
- [5. Secrets Management & Microsoft Entra Workload Identity](#5-Secrets-Management-&-Microsoft-Entra-Workload-Identity)
- [6. Autoscaling](#6-autoscaling)
- [7. Observability & Alerting](#7-observability--alerting)
- [Repository Structure](#repository-structure)
- [Getting Started](#getting-started)
- [Cost Management](#cost-management)
- [Roadmap](#roadmap)

---

## Cluster Overview

```
┌─────────────┐     ┌──────────────┐     ┌───────────────┐
│  Terraform  │────▶│  Azure (AKS, │────▶│    ArgoCD     │
│  (IaC)      │     │  ACR, Vault) │     │ (Application) │
└─────────────┘     └──────────────┘     └───────┬───────┘
                                                 │ sync (dev)
                                                 ▼
                                  ┌──────────────────────────────┐
                                  │        AKS Cluster           │
                                  │  node pool "system"          │
                                  │  ┌────────────┐  ┌────────┐  │
                                  │  │ App Pods   │  │  HPA   │  │
                                  │  │ (Kyverno,  │◀─┤ scales │  │
                                  │  │ NetworkPol)│  └────────┘  │
                                  │  └─────┬──────┘              │
                                  │        │ scrape              │
                                  │  node pool "monitoring"      │
                                  │        │                     │ 
                                  │  ┌─────▼───────┐  (dedicated,│
                                  │  │ Prometheus  │   tainted)  │
                                  │  │  Grafana    │             │
                                  │  │ Alertmanager│             │
                                  │  └─────────────┘             │
                                  └──────────────────────────────┘

CI: GitLab CI → SAST → Trivy scan → Image signing + SBOM → Push to ACR → Update manifest (GitOps)


## Architecture Overview

```text
┌──────────────────────┐
│      GitLab CI       │
│                      │
│ Unit Tests           │
│ SAST                 │
│ Trivy                │
│ Cosign + SBOM        │
└──────────┬───────────┘
           │
           │ Build / Scan / Sign
           ▼
┌──────────────────────┐
 agent-knowledge.md│   Azure Container    │
│      Registry        │
│        (ACR)         │
└──────────┬───────────┘
           │
           │ Image
           ▼
┌────────────────────────────────────────────────────────────┐
│                         Azure                              │
│                                                            │
│  ┌──────────────────┐       ┌──────────────────────────┐   │
│  │    Terraform     │──────▶│     Azure Resources      │   │
│  │       IaC        │       │                          │   │
│  └──────────────────┘       │ AKS / ACR / Key Vault    │   │
│                             └────────────┬─────────────┘   │
│                                          │                 │
│                                          ▼                 │
│  ┌──────────────────────────────────────────────────────┐  │
│  │                    AKS Cluster                       │  │
│  │                                                      │  │
│  │  ┌──────────────────────┐                            │  │
│  │  │       ArgoCD         │                            │  │
│  │  │                      │                            │  │
│  │  │ GitOps reconciliation│                            │  │
│  │  └──────────┬───────────┘                            │  │
│  │             │ sync                                   │  │
│  │             ▼                                        │  │
│  │  ┌──────────────────────────────────────────────┐    │  │ 
│  │  │              Application Pod                 │    │  │
│  │  │                                              │    │  │
│  │  │ Spring Boot                                  │    │  │
│  │  │ ServiceAccount                               │    │  │
│  │  │ HPA                                          │    │  │
│  │  └──────────┬───────────────────────────────────┘    │  │
│  │             │                                        │  │
│  │             │ Federated identity                     │  │
│  │             ▼                                        │  │
│  │  ┌──────────────────────────────────────────────┐    │  │
│  │  │       Microsoft Entra Workload Identity      │    │  │
│  │  │              + AKS OIDC Issuer               │    │  │
│  │  └──────────┬───────────────────────────────────┘    │  │
│  │             │                                        │  │
│  │             ▼                                        │  │
│  │  ┌──────────────────────────────────────────────┐    │  │
│  │  │       User Assigned Managed Identity         │    │  │
│  │  │                    (UAMI)                    │    │  │
│  │  └──────────┬───────────────────────────────────┘    │  │
│  │             │                                        │  │
│  │             │ Azure RBAC                             │  │
│  │             │ Key Vault Secrets User                 │  │
│  │             ▼                                        │  │
│  │  ┌──────────────────────────────────────────────┐    │  │
│  │  │               Azure Key Vault                │    │  │
│  │  │                                              │    │  │
│  │  │          Application secrets                 │    │  │
│  │  └──────────┬───────────────────────────────────┘    │  │
│  │             │                                        │  │
│  │             │ Secret retrieval                       │  │
│  │             ▼                                        │  │
│  │  ┌──────────────────────────────────────────────┐    │  │
│  │  │          Secrets Store CSI Driver            │    │  │
│  │  │           + Azure Key Vault Provider         │    │  │
│  │  └──────────────────────────────────────────────┘    │  │
│  │                                                      │  │
│  │  ┌──────────────────────────────────────────────┐    │  │
│  │  │          Monitoring Node Pool                │    │  │
│  │  │              (dedicated)                     │    │  │
│  │  │                                              │    │  │
│  │  │  Prometheus │ Grafana │ Alertmanager         │    │  │
│  │  └──────────────────────────────────────────────┘    │  │
│  │                                                      │  │
│  │  Runtime Security:                                   │  │
│  │  ┌──────────────┐       ┌──────────────────────┐     │  │
│  │  │   Kyverno    │       │   Network Policies   │     │  │
│  │  │ Policy-as-   │       │    Default-Deny      │     │  │
│  │  │    Code      │       │      + Allow Rules   │     │  │
│  │  └──────────────┘       └──────────────────────┘     │  │
│  │                                                      │  │
│  └──────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────┘


GitOps Flow
───────────

GitLab CI
    │
    │ Update Kubernetes image tag
    ▼
Git Repository
    │
    │ Pull / Reconcile
    ▼
ArgoCD
    │
    │ Apply desired state
    ▼
AKS


Identity & Secrets Flow
───────────────────────

Application Pod
      │
      │ ServiceAccount
      ▼
Microsoft Entra Workload Identity
      │
      │ AKS OIDC Issuer
      ▼
User Assigned Managed Identity
      │
      │ Azure RBAC
      │ Key Vault Secrets User
      ▼
Azure Key Vault
      │
      │ Secret retrieval
      ▼
Secrets Store CSI Driver
      │
      ▼
Application


Observability Flow
──────────────────

Application
      │
      │ /actuator/prometheus
      ▼
Prometheus
      │
      ├───────────────► Grafana
      │
      └───────────────► Alertmanager
                              │
                              ▼
                           Alerts
```

The platform is organized around three complementary flows:

**1. CI/CD and GitOps**

GitLab CI performs testing, security scanning, image signing, SBOM generation, and pushes the validated image to Azure Container Registry. The pipeline then updates the Kubernetes image reference in Git. ArgoCD continuously reconciles the Git repository with the AKS cluster and applies the desired state.

The pipeline therefore **does not deploy directly to Kubernetes**. ArgoCD is responsible for cluster-side deployment and reconciliation.

**2. Identity and Secrets**

Application workloads authenticate to Azure without storing Azure credentials in the container or Kubernetes manifests. A Kubernetes ServiceAccount is federated through the AKS OIDC issuer and Microsoft Entra Workload Identity to a dedicated User Assigned Managed Identity. Azure RBAC grants that identity the required Key Vault permissions, while the Secrets Store CSI Driver retrieves the secrets at runtime.

**3. Observability**

The application exposes JVM and HTTP metrics through Spring Boot Actuator. Prometheus collects these metrics through a Kubernetes `ServiceMonitor`, Grafana provides dashboards, and Alertmanager evaluates and routes alerts based on Prometheus rules.

This architecture combines **Infrastructure as Code, secure CI/CD, GitOps, workload identity, centralized secrets management, runtime security, autoscaling, and observability** into a single Kubernetes platform.

```

The pipeline never deploys directly to the cluster. It builds, scans, signs, and pushes an image, then updates a Kubernetes manifest in Git — **ArgoCD is the only component with write access to the cluster**, pulling the desired state from Git. This split between a *push-based CI* and a *pull-based CD* is the defining principle of GitOps, and it's a deliberate architectural choice here, not a default.

Currently a single ArgoCD `Application` is wired for the `dev` environment (see [Roadmap](#roadmap) for extending this to `staging` / multi-environment).

---

## Tech Stack

| Layer | Tools |
|---|---|
| Infrastructure as Code | Terraform (AKS, ACR, Key Vault, dedicated monitoring node pool, remote state backend) |
| CI/CD | GitLab CI |
| Container Registry | Azure Container Registry (ACR) |
| GitOps / CD | ArgoCD |
| Security — pipeline | SAST, Trivy (image vulnerability scanning, blocking), Cosign image signing + SBOM (Syft) |
| Security — runtime | Kyverno (policy-as-code, enforce mode), Network Policies (default-deny) |
| Identity & Secrets | Microsoft Entra Workload Identity, AKS OIDC issuer, User Assigned Managed Identity, Azure Key Vault, Secrets Store CSI Driver, Azure RBAC |
| Autoscaling | Horizontal Pod Autoscaler (HPA) |
| Observability | Prometheus (kube-prometheus-stack), Grafana, Alertmanager, Micrometer |
| Application | Spring Boot (Java 21), Spring Boot Actuator |

---

## 1. Infrastructure as Code (Terraform)

The entire Azure footprint is provisioned declaratively rather than clicked together manually:

- **`main.tf` / `providers.tf`** — Azure provider configuration and resource group definition.
- **`aks.tf`** — AKS cluster definition: default node pool sizing, Kubernetes version, networking mode, OIDC issuer, Key Vault Secrets Provider add-on.
- **`acr.tf`** — Azure Container Registry, admin account disabled, with role assignments scoped to the AKS managed identity (no static credentials needed to pull images).
- **`keyvault.tf`** — Azure Key Vault instance and RBAC role assignments, feeding the Secrets Store CSI Driver (see [Secrets Management](#5-secrets-management)).
- **`monitoring-node-pool.tf`** — a **dedicated, tainted node pool** for the observability stack (Prometheus, Grafana, Alertmanager), isolated from the application node pool. This separation matters in practice: without it, the monitoring stack and the application compete for the same CPU/memory budget, which becomes a real scheduling bottleneck on small clusters (see troubleshooting log, issue #15).
- **`providers.tf` (backend block)** + **`scripts/bootstrap-backend.sh`** — remote state configuration. Terraform state is stored remotely in Azure Storage (not locally), so state is shared safely and isn't lost/corrupted between machines — the bootstrap script provisions the storage backend itself before the main configuration can run.
- **`outputs.tf` / `variables.tf`** — parameterization for multi-environment reuse (dev/staging) without duplicating the configuration.

**Why it matters technically**: Terraform computes a diff between desired and actual state on every `plan`/`apply`, making infrastructure changes reviewable and reproducible across environments, avoiding the configuration drift manual provisioning inevitably introduces.

---

## 2. Secure CI/CD Pipeline

Every push to `master` triggers a `.gitlab-ci.yml` pipeline that enforces security **before** an image is allowed to exist in the registry, not after:

1. **Unit tests** (Maven).
2. **Static Application Security Testing (SAST)** — GitLab's built-in template scans source code before a container is even built.
3. **Trivy image scan** — scans every OS package and application dependency layer of the built image against CVE databases, configured to **fail the build** (`--exit-code 1`) above HIGH/CRITICAL severity — a vulnerable image cannot physically reach the registry.
4. **Push to ACR**.
5. **Image signing + SBOM** — the image is cryptographically signed with Cosign (keyless, via GitLab's OIDC identity), and a Software Bill of Materials is generated with Syft and attached as an attestation. This closes the loop between "the pipeline scanned it" and "the image's provenance is verifiable."
6. **Manifest update** — the pipeline's final job updates the image tag in `k8s/overlays/dev` and commits it back to the repo (`[skip ci]` to avoid a pipeline loop) — this Git commit is what actually triggers deployment, via ArgoCD, not the pipeline itself.

This is **shift-left security**: checks happen at the earliest possible stage (commit/build time) instead of being discovered in production.

---

## 3. GitOps with ArgoCD

Git is the single source of truth for the cluster's desired state. ArgoCD continuously **reconciles** — it compares what's declared in Git against what's actually running, and automatically corrects drift (`selfHeal: true`) and removes resources no longer declared (`prune: true`).

**Practical benefits demonstrated in this project**:
- **Rollback = `git revert`** — Git history *is* the deployment history, no need to track previous `kubectl` state manually.
- **Full auditability** — every deployment is a commit with an author, timestamp, and diff.
- **No cluster credentials in CI** — the pipeline only ever writes to Git; ArgoCD, running inside the cluster, does the actual pulling and applying. A compromised CI pipeline still can't touch the cluster directly.
- **Environment structure via Kustomize overlays** (`k8s/base` + `k8s/overlays/dev|staging`) — shared base manifests, environment-specific patches (replica count, image tag, namespace) layered on top without duplicating the whole manifest per environment. `staging` currently exists as an overlay but is not yet wired to its own ArgoCD `Application` (see [Roadmap](#roadmap)).

---

## 4. Runtime Security (Defense in Depth)

Independent layers enforce constraints at runtime, so no single misconfiguration compromises the whole cluster:

**Kyverno (`k8s/security/kyverno/`)**, enforced (not just audited):
- `disallow-root-user.yaml` — rejects any pod that doesn't run as a non-root, **numeric** UID at admission time (see troubleshooting issue #10 for why "numeric" specifically matters).
- `disallow-latest-tag.yaml` — rejects any pod referencing an image tagged `:latest`, forcing every deployment to reference an immutable, traceable tag (a Git commit SHA, set automatically by the CI pipeline).

**Network Policies (`k8s/security/network-policies/`)** — a zero-trust networking model, built in explicit layers:
- `default-deny-all.yaml` — the foundation: no traffic is allowed by default, in or out, for any pod in the `dev` namespace.
- `allow-dns.yaml` — without this, `default-deny-all` also blocks DNS resolution to CoreDNS (port 53), breaking everything the app needs to resolve by name. A common first mistake when adopting default-deny (see troubleshooting issue #16).
- `allow-app-ingress.yaml` — the only inbound traffic explicitly permitted: requests to the application's port, which also covers kubelet probes and Prometheus scraping.

**Access control**: no static credentials anywhere in the stack — ACR access is via the AKS managed identity (`AcrPull` role), Key Vault access via a dedicated managed identity (`Key Vault Secrets User` role), and the CI automation token is scoped to the minimum GitLab role needed to push manifest updates.
 agent-knowledge.md
---

## 5. Secrets Management & Microsoft Entra Workload Identity

Secrets are never committed in plaintext manifests, and Azure credentials are not embedded in application workloads.

The platform uses **Microsoft Entra Workload Identity** with the **AKS OIDC issuer**, a **User Assigned Managed Identity (UAMI)**, a Kubernetes **ServiceAccount**, and the **Secrets Store CSI Driver** to securely retrieve secrets from **Azure Key Vault at runtime**.

### Authentication Flow

```text
┌──────────────────────┐
│   Application Pod    │
│                      │
│ Kubernetes           │
│ ServiceAccount       │
└──────────┬───────────┘
           │
           │ ServiceAccount token
           ▼
┌──────────────────────┐
│    AKS OIDC Issuer   │
└──────────┬───────────┘
           │
           │ Federated Identity Credential
           ▼
┌──────────────────────┐
│   Microsoft Entra ID  │
└──────────┬───────────┘
           │
           │ Federated authentication
           ▼
┌────────────────────────────┐
│ User Assigned Managed      │
│ Identity (UAMI)            │
└──────────┬─────────────────┘
           │
           │ Azure RBAC
           │ Key Vault Secrets User
           ▼
┌────────────────────────────┐
│      Azure Key Vault       │
│                            │
│       Application secrets  │
└──────────┬─────────────────┘
           │
           │ Runtime retrieval
           ▼
┌────────────────────────────┐
│ Secrets Store CSI Driver   │
│ + Azure Key Vault Provider │
└────────────────────────────┘
```

### How Workload Identity works

The Kubernetes workload does not store an Azure client secret, password, or long-lived service principal credential.

Instead, the workload runs with a dedicated Kubernetes **ServiceAccount**. The AKS cluster exposes an **OIDC issuer**, which establishes a trusted identity source for Microsoft Entra ID.

A **Federated Identity Credential** creates the trust relationship between:

* the AKS OIDC issuer;
* the Kubernetes ServiceAccount;
* the User Assigned Managed Identity.

When the application needs to access Azure resources, Microsoft Entra ID validates the federated identity and provides authentication for the associated managed identity.

The UAMI is then authorized through **Azure RBAC** to access only the required Key Vault resources.

This provides identity-based access without embedding static Azure credentials inside the application or Kubernetes manifests.

### Key Components

| Component                             | Role                                                            |
| ------------------------------------- | --------------------------------------------------------------- |
| **AKS OIDC Issuer**                   | Provides the trusted identity issuer for Kubernetes workloads   |
| **Microsoft Entra Workload Identity** | Enables federated authentication between Kubernetes and Azure   |
| **Kubernetes ServiceAccount**         | Represents the application's workload identity inside AKS       |
| **Federated Identity Credential**     | Establishes trust between the ServiceAccount and UAMI           |
| **User Assigned Managed Identity**    | Provides the Azure identity used by the workload                |
| **Azure RBAC**                        | Controls access to Azure resources using least privilege        |
| **Azure Key Vault**                   | Centralized storage for application secrets                     |
| **Secrets Store CSI Driver**          | Retrieves and exposes Key Vault secrets to Kubernetes workloads |
| **Azure Key Vault Provider**          | Connects the CSI Driver to Azure Key Vault                      |

### SecretProviderClass

The `SecretProviderClass` declares how the workload connects to Azure Key Vault without containing the actual secret values.

The manifest contains only the **configuration required to retrieve the secret**. The actual secret value remains stored in Azure Key Vault.

### Runtime Secret Retrieval

The complete process is:

```text
Git
 │
 │ Kubernetes manifests only
 ▼
SecretProviderClass
 │
 ▼
Application Pod
 │
 │ ServiceAccount identity
 ▼
Microsoft Entra Workload Identity
 │
 ▼
User Assigned Managed Identity
 │
 │ Key Vault Secrets User
 ▼
Azure Key Vault
 │
 │ Secret value
 ▼
Secrets Store CSI Driver
 │
 ▼
Application
```

This creates a clear separation between **deployment configuration** and **secret data**:

```text
Configuration ────────► Git / Kubernetes manifests
Secret values ────────► Azure Key Vault
Workload identity ────► Microsoft Entra Workload Identity
Authorization ────────► Azure RBAC
```

### Security Benefits

This architecture eliminates the need to store long-lived Azure credentials inside application workloads.

It provides:

* **No Azure client secrets stored in Git**.
* **No Azure credentials embedded in container images**.
* **No static Azure credentials required by the application pod**.
* **Federated authentication through AKS OIDC**.
* **Dedicated identity per workload** through a User Assigned Managed Identity.
* **Least-privilege access** through Azure RBAC.
* **Centralized secret management** with Azure Key Vault.
* **Runtime secret retrieval** instead of hardcoding secret values.
* **Secret rotation support** without rebuilding the application image.
* A clear separation between **GitOps configuration** and **sensitive secret data**.

### Secret Rotation

Secrets are managed centrally in Azure Key Vault rather than being versioned with the application configuration.

When a secret is rotated in Key Vault, the Secrets Store CSI Driver can synchronize the updated value according to the configured rotation mechanism.

This means secret changes can be managed independently from the application image and Git repository.

The deployment pipeline therefore does not need to contain or transmit the secret value itself.

### Infrastructure as Code

The identity and access model is designed to be reproducible through Infrastructure as Code.

Terraform is responsible for the Azure-side resources and permissions, including:

* AKS workload identity / OIDC configuration;
* User Assigned Managed Identity;
* Azure Key Vault;
* Azure RBAC role assignments;
* required Key Vault integration components.

Kubernetes manifests define the workload-side configuration:

* ServiceAccount;
* workload identity annotations/labels;
* SecretProviderClass;
* application Deployment;
* CSI volume configuration.

This results in a declarative security model where **identity, authorization, secret storage, and workload configuration are explicitly defined rather than manually configured through the portal**.

---

## 6. Autoscaling

`k8s/base/hpa.yaml` defines a **Horizontal Pod Autoscaler** that scales the application's replica count (1 to 4) based on observed CPU and memory utilization against the requests defined in the Deployment. HPA thresholds are only meaningful if the underlying resource *requests* are realistic — this is directly tied to the capacity issues documented in troubleshooting issue #15.

---

## 7. Observability & Alerting

**Metrics collection**: Prometheus (`kube-prometheus-stack`, configured via `observability/values-monitoring.yaml`, scheduled on the dedicated `monitoring` node pool) scrapes two levels of metrics:
- **Infrastructure-level** — node-exporter, kube-state-metrics, available out of the box.
- **Application-level** — JVM and HTTP metrics exposed by the Spring Boot app via Micrometer/Actuator (`/actuator/prometheus`), discovered through the `ServiceMonitor` in `k8s/overlays/dev/servicemonitor.yaml`. Prometheus does **not** auto-discover custom applications — this has to be declared explicitly, and the ServiceMonitor's `release` label must match what the Helm release expects, or it's silently ignored (see troubleshooting issue #13).

**Dashboards**: `observability/dashboard-portfolio-app.json` is a Grafana dashboard **versioned in the repository** and loaded automatically via a labeled ConfigMap (`observability/dashboard-configmap.yaml`), rather than existing only as a manually imported dashboard in the Grafana UI — the visualization is reproducible and survives a Grafana pod restart, not a manual click-through step that has to be redone.

To find it: open Grafana (see [Getting Started](#getting-started)), go to **Dashboards** in the left sidebar — it appears in the list as **"Portfolio App - Vue d'ensemble"**, no manual import needed. It shows HTTP request rate by status, p95 latency, CPU usage against limits, and current HPA replica count.

**Alerting**: `k8s/overlays/dev/alerts.yaml` defines `PrometheusRule` resources evaluated continuously:
- Pod crash-loop detection.
- Sustained high CPU usage (>80%, correlated with whether the HPA is responding).
- Pod not-ready for a prolonged period.

Alertmanager (part of `kube-prometheus-stack`) receives firing alerts, closing the loop from *metric* → *rule evaluation* → *alert*, rather than leaving dashboards as something that has to be watched manually to be useful.

---

## Repository Structure

```
## Repository Structure

```text
.
├── .gitignore
├── .gitlab-ci.yml                         # GitLab CI/CD pipeline
├── CONTRIBUTING.md
├── Dockerfile                             # Multi-stage, non-root container
├── LICENSE
│
├── argocd/
│   ├── application-dev.yaml                # ArgoCD Application (dev)
│   └── kustomization.yaml
│
├── docs/
│   ├── agent-knowledge.md
│   ├── architecture/                      # Architecture documentation
│   ├── screenshots/                        # Project screenshots
│   │   ├── argocd/
│   │   ├── azure/
│   │   ├── cluster/
│   │   ├── grafana/
│   │   ├── pipeline/
│   │   └── prometheus/
│   └── troubleshooting.md                  # Real troubleshooting log
│
├── k8s/
│   ├── base/
│   │   ├── ai-agent/
│   │   │   ├── auth/                       # Authentication configuration
│   │   │   ├── cluster-issuer-prod.yaml   # TLS certificate issuer
│   │   │   ├── cluster-issuer-staging.yaml
│   │   │   ├── ingress.yaml                # AI agent ingress
│   │   │   ├── kubernetes-mcp-config.yaml # Kubernetes MCP configuration
│   │   │   ├── kubernetes-mcp-deployment.yaml
│   │   │   ├── namespace.yaml
│   │   │   ├── networkpolicy.yaml          # AI agent network isolation
│   │   │   ├── prometheus-mcp-deployment.yaml
│   │   │   ├── pushgateway-deployment.yaml
│   │   │   └── rbac.yaml                   # Kubernetes RBAC for the agent
│   │   │
│   │   ├── deployment.yaml                 # Application Deployment
│   │   ├── hpa.yaml                         # Horizontal Pod Autoscaler
│   │   ├── kustomization.yaml
│   │   ├── secret-provider-class.yaml      # Azure Key Vault CSI integration
│   │   ├── service.yaml
│   │   └── serviceaccount.yaml              # Workload Identity ServiceAccount
│   │
│   ├── overlays/
│   │   ├── dev/
│   │   │   ├── alerts.yaml                  # Prometheus alerting rules
│   │   │   ├── kustomization.yaml
│   │   │   └── servicemonitor.yaml          # Application metrics discovery
│   │   └── staging/
│   │       └── kustomization.yaml            # Staging overlay
│   │
│   └── security/
│       ├── kyverno/
│       │   ├── disallow-latest-tag.yaml
│       │   └── disallow-root-user.yaml
│       └── network-policies/
│           ├── allow-app-ingress.yaml
│           ├── allow-dns.yaml
│           ├── default-deny-all.yaml
│           └── kustomization.yaml
│
├── observability/
│   ├── dashboard-configmap.yaml             # Grafana dashboard provisioning
│   ├── dashboard-portfolio-app.json         # Grafana dashboard definition
│   └── values-monitoring.yaml               # kube-prometheus-stack values
│
├── scripts/
│   └── bootstrap-backend.sh                 # Terraform remote backend bootstrap
│
├── src/
│   ├── main/
│   │   ├── java/
│   │   │   └── com/                         # Spring Boot application source
│   │   └── resources/
│   │       └── application.properties
│   └── test/
│       └── java/
│           └── com/                         # Application tests
│
├── terraform/
│   ├── acr.tf                               # Azure Container Registry
│   ├── aks.tf                               # AKS + OIDC / Workload Identity
│   ├── backend.tf                           # Remote Terraform backend
│   ├── foundry.tf                           # Azure AI Foundry resources
│   ├── keyvault.tf                          # Azure Key Vault + RBAC
│   ├── main.tf
│   ├── monitoring-node-pool.tf              # Dedicated monitoring node pool
│   ├── outputs.tf
│   ├── providers.tf
│   └── variables.tf
│
├── pom.xml                                  # Maven configuration
├── mvnw / mvnw.cmd                           # Maven Wrapper
└── readme.md
```

### Key Architectural Areas

* **`terraform/`** — Azure infrastructure provisioned through Infrastructure as Code, including AKS, ACR, Azure Key Vault, monitoring infrastructure, and Azure AI Foundry resources.
* **`k8s/base/`** — reusable Kubernetes resources shared across environments.
* **`k8s/base/ai-agent/`** — Kubernetes manifests for the AI-powered incident investigation components, including Kubernetes MCP, Prometheus MCP, Pushgateway, RBAC, networking, ingress, and authentication.
* **`k8s/overlays/`** — environment-specific Kustomize configuration for `dev` and `staging`.
* **`k8s/security/`** — runtime security policies using Kyverno and Kubernetes NetworkPolicies.
* **`observability/`** — Prometheus/Grafana configuration and dashboard provisioning.
* **`argocd/`** — GitOps application definitions used by ArgoCD.
* **`docs/`** — architecture documentation, screenshots, and the real troubleshooting history.
* **`src/`** — Spring Boot application source code and tests.

The repository therefore contains both the **platform infrastructure** and the **application workload**, with infrastructure, security, identity, observability, GitOps, and AI-assisted incident investigation represented declaratively in code.

---

## Getting Started

```bash
# 1. Bootstrap the Terraform remote state backend (one-time)
./scripts/bootstrap-backend.sh

# 2. Provision infrastructure
cd terraform && terraform init && terraform apply

# 3. Install ArgoCD and Kyverno
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl apply -f https://github.com/kyverno/kyverno/releases/latest/download/install.yaml
kubectl apply -f k8s/security/kyverno/

# 4. Deploy the application (ArgoCD takes over from here)
kubectl apply -f argocd/application-dev.yaml

# 5. Install observability
helm install monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring -f observability/values-monitoring.yaml
kubectl apply -f k8s/overlays/dev/alerts.yaml
kubectl apply -f observability/dashboard-configmap.yaml

# 6. Verify metrics are being scraped
kubectl port-forward -n monitoring svc/monitoring-kube-prometheus-prometheus 9090:9090
# → Status > Targets should show portfolio-app as UP

# 7. Access Grafana
kubectl port-forward -n monitoring svc/prometheus-stack-grafana 3000:80
# → login: admin / <password set at install>
# → Dashboards (left sidebar) > "Portfolio App - Vue d'ensemble"
```

Full step-by-step detail, including every error actually hit along the way, is in [`docs/troubleshooting.md`](./docs/troubleshooting.md).

---

## Cost Management

- Infrastructure destroyed (`terraform destroy`) or scaled down (`az aks stop`, monitoring node pool scaled to 0) between work sessions.
- The `monitoring` node pool is isolated specifically so it can be scaled independently of the application pool without affecting it.
- An Azure budget alert was configured as soon as the first billable resources were added.

---

## Screenshots

[`docs/screenshots`](docs/screenshots)

## Roadmap

- [ ] Wire a `staging` ArgoCD `Application` to complete the promotion path (currently only `dev` is deployed).
- [ ] Automate the `staging` overlay's image tag update (currently automated for `dev` only).
- [ ] Add Kubernetes RBAC (custom Roles/RoleBindings) for the application's ServiceAccount — currently relies on Azure IAM role assignments only, not in-cluster RBAC restrictions.
- [ ] Add screenshots (Prometheus targets, Grafana dashboard, green pipeline, firing alert) to this README.
- [ ] Load-test the HPA thresholds to confirm scaling behavior under realistic traffic.

---

**Author**: Hajar Zouhair — DevOps/DevSecOps Engineer
