# AI Incident Investigator — Azure AI Foundry & Kubernetes

An AI-powered incident investigation agent built on top of the **Azure Kubernetes Service (AKS)** platform, designed to assist with **real-time Kubernetes troubleshooting and observability-driven incident analysis**. The agent connects operational telemetry, Kubernetes cluster information, Prometheus metrics, logs, and the project knowledge base to investigate incidents, identify potential root causes, and provide actionable remediation guidance.

The solution is built around **Azure AI Foundry**, with secure access to Azure and Kubernetes resources through **Microsoft Entra Workload Identity**, avoiding long-lived credentials inside the agent workload. The agent can interact with the Kubernetes environment through dedicated tools and consume observability data from the monitoring stack to correlate application behavior, resource usage, and cluster events.

> The AI agent is an operational extension of the Secure Cloud Platform on Azure. It does not replace Kubernetes, Prometheus, Grafana, or ArgoCD; instead, it uses the information exposed by these components to accelerate incident investigation and troubleshooting.

> The complete DevSecOps, GitOps, security, workload identity, autoscaling, and observability architecture is documented in [~/hajar-azure-project/docs/devsecops-README.md](~/hajar-azure-project/docs/devsecops-README.md).

---

## Architecture Overview

![Architecture Overview](agent_architecture/architecture_agent.png)


The AI Incident Investigator sits on top of the existing Kubernetes platform and connects **Azure AI Foundry**, **Kubernetes tools**, **Prometheus metrics**, **application logs**, and the **project knowledge base** into a single investigation workflow.

The agent therefore provides an intelligent investigation layer above the existing **DevSecOps + GitOps + Observability** platform, while preserving the security boundaries and identity mechanisms already established in the cluster.

# AI Incident Investigation Agent — Complete Technical README

This document covers the entire AI/agent portion of the DevSecOps portfolio
project: scope, architecture, build steps, and every real incident
encountered and resolved along the way. It supersedes and merges the
earlier `agent-knowledge.md` drafts, the RAG/Knowledge Base notes, and the
AI Security Review notes into a single up-to-date reference.

---

## 1. Why this exists

The existing DevSecOps pipeline (Terraform, GitLab CI, ArgoCD, Kyverno,
Prometheus/Grafana on AKS) produces a lot of signals — Kubernetes events,
metrics, security scan reports — that a human normally has to correlate
manually to diagnose an incident. This project adds an AI agent that
accelerates that correlation, without replacing the underlying scanners,
policies, or GitOps controls.

## 2. Scope, defined before any implementation

- **Single responsibility**: diagnose, never act. The agent has no
  write access anywhere — no scale, delete, restart, or patch.
- **Namespace covered**: `dev` (where `portfolio-app` runs). The
  `monitoring` namespace is queried read-only for metrics, never
  investigated directly.
- **Data sources allowed**: Kubernetes API (read-only), Prometheus,
  application logs via the Kubernetes API, and a documentation
  Knowledge Base. Azure Monitor / Log Analytics was explicitly
  excluded — Prometheus already covers metrics, and adding Azure
  Monitor would duplicate cost and complexity without clear benefit.
- **Mandatory response format** for investigations:
  ```
  Root Cause: ...
  Evidence: ...
  Impact: ...
  Recommended Fix: ...
  ```
- **Success criterion**: reliably and repeatably diagnose real or
  staged incidents, citing concrete evidence per tool call — not just
  occasionally producing a plausible-sounding answer.

## 3. Final architecture

```
                         ┌────────────────────────────┐
                         │   Azure AI Foundry         │
                         │   Agent: k8s-incident-     │
                         │   investigator             │
                         │   Model: gpt-5-mini        │
                         │   (GlobalStandard SKU)     │
                         └──────────────┬─────────────┘
                                        │
              ┌─────────────────────────┼─────────────────────────┐
              │                         │                         │
           MCP tool                  MCP tool                Knowledge Base
         (Kubernetes,              (Prometheus,                  MCP
          read-only)                read-only)             (Azure AI Search)
              │                         │                         │
              ▼                         ▼                         ▼
   ┌───────────────────────────────────────────┐      ┌───────────────────────┐
   │  Ingress (Basic Auth + Let's Encrypt TLS) │      │  Azure Blob Storage   │
   │  namespace: ai-agent, scheduled on the    │      │  → AI Search Indexer  │
   │  "monitoring" node pool                   │      │  → Index (365 docs)   │
   │  ├── kubernetes-mcp-server                │      │  → Knowledge Base     │
   │  ├── prometheus-mcp-server                │      └───────────────────────┘
   │  └── Prometheus Pushgateway               │
   └───────────────────┬───────────────────────┘
                       │
                       ▼
             ┌─────────────────────┐
             │   Cluster AKS       │
             │   namespace: dev    │
             │   Prometheus/Grafana│
             └─────────────────────┘

     ┌───────────────────────────────────────────────────────┐
     │  GitLab CI — job `ai_security_review`                 │
     │  Dedicated identity (AI_REVIEW_CLIENT_ID), separate   │
     │  from the ACR pipeline identity, OIDC-federated,      │
     │  role "Foundry Agent Consumer" scoped to the Project  │
     │       → summarized Trivy + SAST + SBOM reports        │
     │       → AI-generated analysis (ai-security-report.md) │
     │       → success/failure metrics pushed to Pushgateway │
     └───────────────────────────────────────────────────────┘
```

## 4. Components and key decisions

| Component | Choice | Why |
|---|---|---|
| Model | `gpt-5-mini`, SKU `GlobalStandard` | Cost-efficient, token-based billing. The originally planned `gpt-4o-mini` (SKU `Standard`) was rejected by Azure mid-project — see §6.1 |
| Foundry auth | Azure AD only (`local_auth_enabled = false`) | Consistent with the rest of the project (ACR, Key Vault) — no static API keys |
| Kubernetes MCP | `containers/kubernetes_mcp_server` (note: underscore in the real image repo, not a hyphen) | Actively maintained, configurable strict read-only mode, explicit denial of `Secret` resources |
| Prometheus MCP | `pab1it0/prometheus-mcp-server` (pinned version, HTTP transport enabled via env vars) | Read-only by design |
| MCP exposure | NGINX Ingress + Basic Auth + Let's Encrypt (production) | Foundry is a managed service outside the cluster VNet; public authenticated endpoint was the pragmatic choice over VNet injection for a portfolio project |
| Knowledge Base | Azure Blob Storage → Azure AI Search (indexer/index) → Search-based Knowledge Base → MCP connection into the Foundry Project | Chosen over the basic File Search setup originally planned, for a fully passwordless, RBAC-based retrieval pipeline (see §5) |
| AI Security Review | Direct REST call from a dedicated CI job, not a persistent MCP tool | Security reports are generated once per pipeline run; a dedicated always-on MCP server would be disproportionate |
| Observability of the agent | Prometheus Pushgateway | A CI job is ephemeral; Prometheus scrapes in pull mode, so the Pushgateway bridges the gap |

## 5. Knowledge Base (RAG) — as actually built

Rather than the basic Foundry File Search originally planned, the
Knowledge Base was built as a fully-managed, passwordless retrieval
pipeline:

```
Git repo (agent-knowledge.md, troubleshooting.md, CI config,
Terraform, K8s manifests, Kyverno policies)
        │  upload
        ▼
Azure Blob Storage (stfhajarazuredev / knowledge-documents)
        │  data source: hajar-index-datasource
        ▼
Azure AI Search
        │  indexer: hajar-index-indexer
        ▼
Index: hajar-index (365 documents, ~16.7 MB)
        │
        ▼
Knowledge Base: "knowledgebase"
        │  MCP endpoint:
        │  https://<search-service>.search.windows.net/knowledgebases/knowledgebase/mcp
        ▼
Foundry Project connection: kb-knowledgebase-qfyjx
  - category: RemoteTool
  - authType: ProjectManagedIdentity
  - audience: https://search.azure.com/
        ▼
Agent: k8s-incident-investigator
```

**Identities and RBAC involved:**
- Azure AI Search uses a **System Assigned Managed Identity** with
  `Storage Blob Data Reader` on the storage account and
  `Cognitive Services OpenAI User` on the Foundry resource (needed for
  the indexer's enrichment skills).
- The Foundry **Project's own managed identity** holds
  `Search Index Data Reader` on the Azure AI Search service — this is
  what lets the agent query the Knowledge Base without any API key.
- Azure AI Search has `disableLocalAuth: true` — no API key access at
  all; everything goes through Microsoft Entra ID + RBAC.

**Validation performed:**
- Indexer run: `status: success, processed: 1, failed: 0`.
- Direct `GET /indexes` against the Search service with Entra ID auth
  returned `200`.
- `GET` on the Knowledge Base MCP endpoint returned `405 Allow: POST`
  — expected, confirms the endpoint is reachable and enforces the MCP
  protocol correctly.
- Grounding test: asked the agent about a specific troubleshooting
  entry (the `westeurope` region rejection encountered during initial
  Terraform provisioning — see §6.7); the agent correctly retrieved
  the exact symptom (`RequestDisallowedByAzure`) and the fix
  (switching to `francecentral`) from `troubleshooting.md`, proving
  the retrieval chain works end-to-end rather than falling back to
  generic model knowledge.

## 6. Troubleshooting log

Every real incident encountered while building this agent — model
deprecation, quota limits, RBAC gaps, TLS/networking issues, CI
authentication failures, and more — is documented separately in
[`ai-agent/docs/ai-agent-troubleshooting.md`](ai-agent-troubleshooting.md), in the order it
occurred. Kept out of this file so architecture and incident history
stay independently readable.

## 7. Validated real-world result: readiness probe investigation

As a live test (not a scripted demo), the Deployment's readiness probe
path was intentionally broken (`/actuator/health/readyz` instead of
the real `/actuator/health/readiness`) while ArgoCD's `self-heal` was
temporarily disabled. Asked to investigate, the agent independently:

- Listed pods, fetched pod details, cluster events, the Deployment
  spec, application logs, the Service definition, and the HPA state —
  six different tool calls, each cited individually as evidence.
- Correctly identified the exact one-character discrepancy
  (`readyz` vs. `readiness`) between the probe configuration and the
  application's real Spring Boot Actuator endpoint.
- Cross-referenced a live Prometheus query
  (`kube_pod_container_status_ready`) confirming the container's
  unready state, rather than relying on Kubernetes state alone.
- Correctly scoped the blast radius (single replica → total dev
  outage; HPA unable to compute CPU-based scaling metrics with no
  Ready pods).
- Proposed a fix without executing it, in line with its
  diagnose-only mandate — including a secondary option (exposing a
  `/readyz` alias in the app instead of just fixing the probe path).

This is the strongest evidence in the project that the agent performs
genuine multi-source correlation rather than pattern-matching a single
signal.

## 8. AI Security Review — pipeline integration

```yaml
stages:
  - test
  - build
  - scan
  - push
  - sign
  - ai_review
  - deploy
```

The `ai_security_review` job:
- Depends on `container_scan`, `sast`, and `sign_and_sbom` artifacts.
- Authenticates via its own OIDC-federated identity
  (`AI_REVIEW_CLIENT_ID`), fully separate from the ACR pipeline
  identity — least privilege between unrelated workflows.
- Performs the token exchange, calls the Foundry agent's Responses
  API, and writes `ai-security-report.md` as a pipeline artifact
  (`when: always`, so the report survives even when the scan itself
  fails a job).
- Pushes success/failure and duration metrics to the Prometheus
  Pushgateway, visible in Grafana (see §9).

`container_scan` currently reports but does not hard-block the
pipeline on findings (`|| true` on the Trivy exit-code check) — this
was a deliberate temporary choice to capture a real CVE example for
the AI Security Review without blocking iteration. **This should be
reverted to a real blocking gate (remove `|| true`) or explicitly
documented as a permanent, intentional demo choice before treating the
project as final** — leaving it silently disabled would undermine the
project's own security narrative.

## 9. Observability of the agent (Prometheus + Grafana)

A CI job is ephemeral and Prometheus scrapes in pull mode, so a
Pushgateway bridges the two: `ai_security_review` pushes a metric on
every run, whether it succeeds or fails.

**Metrics exposed:**
```
ai_agent_call_total{status="success"|"failure"}
ai_agent_call_duration_seconds
```

**Pipeline:** `Pushgateway (namespace ai-agent, monitoring node pool)`
→ scraped by Prometheus via a `ServiceMonitor` (label matched to the
`kube-prometheus-stack` release name — verify this against
`kubectl get servicemonitor -n monitoring` rather than assuming a
generic value, it caused a false negative during setup) → visualized
in Grafana.

**Grafana panels**, added to the project's existing dashboard:
```promql
sum by (status) (ai_agent_call_total)       # request rate by status
avg(ai_agent_call_duration_seconds)          # p-average latency
```

**Dashboard-as-code:** the dashboard is no longer imported manually
through the Grafana UI (which does not survive a Grafana pod restart
or a cluster rebuild — manually imported dashboards live only in
Grafana's internal SQLite storage). It is now defined as a
`ConfigMap` labeled `grafana_dashboard: "1"` in
`k8s/base/ai-agent/grafana-dashboard-configmap.yaml`, picked up
automatically by the `kube-prometheus-stack` Grafana sidecar. This
makes the dashboard fully reproducible: it reappears automatically
after any `terraform destroy` + `apply` cycle, with no manual import
step — confirmed working, including the agent-specific panels above.

**Known limitation:** only CI-triggered calls are observed; the
Foundry portal's interactive chat usage is not (see §10.4). And the
Basic Auth credential shared by the Ingress now has to stay in sync
across four separate places — the Kubernetes secret, the
`PUSHGATEWAY_AUTH` GitLab CI/CD variable, and the `Authorization`
header configured on **both** Foundry MCP tools
(`kubernetes-cluster` and `prometheus-metrics`). Rotating it in only
one location silently breaks the others with a `401` — this was hit
in practice (see `troubleshooting.md`) and is a legitimate argument
for a per-consumer credential or a managed secret rotation setup as a
future improvement, not a one-off mistake to just avoid repeating.

## 10. What the agent explicitly does NOT do

- No write actions on the cluster, ever — diagnosis only.
- No Azure Monitor / Log Analytics integration — Prometheus already
  covers metrics; adding it was judged unnecessary cost/complexity.
- No private networking (VNet injection) between Foundry and the MCP
  servers — a publicly exposed, authenticated Ingress was used
  instead, a deliberate trade-off for a portfolio-scale project.
- No observability of interactive chat usage in the Foundry portal —
  only CI-triggered calls are currently monitored (§9); full coverage
  would require Application Insights.
- The Foundry Project and Agent themselves are not Terraform-managed
  — only the underlying Cognitive Services account and model
  deployment are; the Project/Agent were created via the Azure
  portal, a current limitation of the `azurerm` provider on this
  resource model.

## 11. Roadmap

- Human-in-the-loop: agent proposes a fix, a human approves, a
  commit/PR is generated automatically.
- Full Azure Monitor / Log Analytics integration.
- VNet injection for private connectivity between Foundry and AKS.
- Full agent observability, including interactive portal usage, via
  Application Insights.
- Expand coverage to a `staging` namespace.
- Revisit the Trivy blocking gate decision noted in §8.
