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
- [5. Secrets Management](#5-secrets-management)
- [6. Autoscaling](#6-autoscaling)
- [7. Observability & Alerting](#7-observability--alerting)
- [Repository Structure](#repository-structure)
- [Getting Started](#getting-started)
- [Cost Management](#cost-management)
- [Roadmap](#roadmap)

---

## Architecture Overview

```
┌─────────────┐     ┌──────────────┐     ┌───────────────┐
│  Terraform  │────▶│  Azure (AKS, │────▶│    ArgoCD      │
│  (IaC)      │     │  ACR, Vault) │     │  (Application) │
└─────────────┘     └──────────────┘     └───────┬────────┘
                                                   │ sync (dev)
                                                   ▼
                                  ┌─────────────────────────────┐
                                  │        AKS Cluster           │
                                  │  node pool "system"          │
                                  │  ┌────────────┐  ┌────────┐  │
                                  │  │ App Pods   │  │  HPA   │  │
                                  │  │ (Kyverno,  │◀─┤ scales │  │
                                  │  │  NetworkPol)│  └────────┘  │
                                  │  └─────┬──────┘              │
                                  │        │ scrape              │
                                  │  node pool "monitoring"      │
troubleshooting.md                                  │  ┌─────▼──────┐  (dedicated, │
                                  │  │ Prometheus │   tainted)   │
                                  │  │  Grafana   │              │
                                  │  │ Alertmanager│             │
                                  │  └────────────┘              │
                                  └─────────────────────────────┘

CI: GitLab CI → SAST → Trivy scan → Image signing + SBOM → Push to ACR → Update manifest (GitOps)
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
| Secrets management | Azure Key Vault via Secrets Store CSI Driver, Azure IAM role assignments (least-privilege access) |
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
- `require-resource-limits.yaml` — rejects any pod without explicit CPU/memory requests and limits.

**Network Policies (`k8s/security/network-policies/`)** — a zero-trust networking model, built in explicit layers:
- `default-deny-all.yaml` — the foundation: no traffic is allowed by default, in or out, for any pod in the `dev` namespace.
- `allow-dns.yaml` — without this, `default-deny-all` also blocks DNS resolution to CoreDNS (port 53), breaking everything the app needs to resolve by name. A common first mistake when adopting default-deny (see troubleshooting issue #16).
- `allow-app-ingress.yaml` — the only inbound traffic explicitly permitted: requests to the application's port, which also covers kubelet probes and Prometheus scraping.

**Access control**: no static credentials anywhere in the stack — ACR access is via the AKS managed identity (`AcrPull` role), Key Vault access via a dedicated managed identity (`Key Vault Secrets User` role), and the CI automation token is scoped to the minimum GitLab role needed to push manifest updates.

---

## 5. Secrets Management

Secrets are never committed in plaintext manifests. `k8s/base/secret-provider-class.yaml` configures the **Secrets Store CSI Driver** with the Azure Key Vault provider: instead of storing a Kubernetes `Secret` object (only base64-encoded, not encrypted, by default), the pod mounts secrets **directly from Azure Key Vault at runtime** as a volume, and Terraform (`keyvault.tf`) grants a dedicated managed identity read access to that vault.

This resolves the apparent tension in GitOps between "everything must be declared in Git" and "secrets must never be in Git" — the `SecretProviderClass` manifest *is* committed (it just says "fetch this secret name from this vault"), but the actual secret value never touches the repository or Kubernetes' etcd store in plaintext.

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
.
├── readme.md
├── .gitlab-ci.yml                          # CI: test, build, SAST, Trivy, sign+SBOM, push, update manifest
├── Dockerfile                              # Multi-stage, non-root numeric UID
├── argocd/
│   └── application-dev.yaml                # ArgoCD Application (dev environment)
├── docs/
│   ├── architecture.md
│   └── troubleshooting.md                  # Real debugging log (18 incidents)
│   └── screenshots
├── k8s/
│   ├── base/
│   │   ├── deployment.yaml
│   │   ├── service.yaml
│   │   ├── hpa.yaml                        # Horizontal Pod Autoscaler
│   │   ├── secret-provider-class.yaml      # Azure Key Vault CSI integration
│   │   └── kustomization.yaml
│   ├── overlays/
│   │   ├── dev/
│   │   │   ├── servicemonitor.yaml
│   │   │   ├── alerts.yaml
│   │   │   └── kustomization.yaml
│   │   └── staging/
│   │       └── kustomization.yaml          # defined, not yet wired to ArgoCD
│   └── security/
│       ├── kyverno/
│       │   ├── disallow-latest-tag.yaml
│       │   ├── disallow-root-user.yaml
│       │   └── require-resource-limits.yaml
│       └── network-policies/
│           ├── default-deny-all.yaml
│           ├── allow-dns.yaml
│           ├── allow-app-ingress.yaml
│           └── kustomization.yaml
├── observability/
│   ├── dashboard-portfolio-app.json
│   ├── dashboard-configmap.yaml            # persists the dashboard across Grafana restarts
│   └── values-monitoring.yaml              # kube-prometheus-stack Helm values (node pool tolerations)
├── scripts/
│   └── bootstrap-backend.sh                # Provisions the Terraform remote state backend
├── src/main/java/.../DemoApplication.java  # Spring Boot application
├── src/main/resources/application.properties
└── terraform/
    ├── main.tf / providers.tf
    ├── aks.tf / acr.tf / keyvault.tf
    ├── monitoring-node-pool.tf             # Dedicated, tainted node pool for observability
    └── variables.tf / outputs.tf
```

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
kubectl port-forward -n monitoring svc/monitoring-grafana 3000:80
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
