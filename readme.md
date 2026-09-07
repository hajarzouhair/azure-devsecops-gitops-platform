# Hajar Zouhair Azure Project — DevSecOps Platform with an AI Incident Investigation Agent

A production-style DevSecOps pipeline on Azure/AKS — supply-chain
security, policy-as-code, and zero-trust networking, extended with an
AI agent that investigates cluster incidents by correlating live
Kubernetes state, metrics, and the project's own documentation.

This is not two unrelated projects bolted together. The agent exists
*because* the DevSecOps pipeline produces more signal (scan reports,
events, metrics) than a human can correlate by hand on every run — it
was built to close that gap, not to add AI for its own sake.

---

## Why this project is worth a closer look

- **Every credential is either short-lived or eliminated.** GitLab
  authenticates to Azure via OIDC federation for both the registry
  push and the AI review job — two separate, least-privilege
  identities, zero long-lived secrets in CI. Key Vault access uses
  Entra Workload Identity. Azure AI Search and the Foundry Knowledge
  Base run with local auth disabled entirely, RBAC-only.
- **Security gates are real, not decorative.** Kyverno runs in
  Enforce mode and has actually rejected non-compliant manifests
  during development (see the troubleshooting logs) — not just in
  theory. Images are signed keylessly with Cosign/Sigstore and
  shipped with an SPDX SBOM.
- **The AI agent is scoped deliberately, not maximally.** It can
  diagnose; it cannot act. That boundary is enforced in the system
  prompt and never crossed once during testing, including when
  directly asked to.
- **Every incident below is real**, captured with the actual error
  message, root cause, and fix — including two occasions where an
  initial fix attempt was itself wrong and had to be corrected. That
  history is kept, not cleaned up, because it's a more honest signal
  of engineering process than a repo that only shows the final state.

## Architecture at a glance

Two independent diagrams, because the two halves of this project have
different concerns and different failure modes:

| | |
|---|---|
| **DevSecOps pipeline** | Build → SAST → Trivy scan → Cosign sign + SBOM → GitOps deploy, wrapped in Kyverno policy enforcement and zero-trust network policies |
| **AI agent** | Azure AI Foundry agent, connected to a read-only Kubernetes MCP tool, a read-only Prometheus MCP tool, and a Knowledge Base built on Azure AI Search |

See each component's README for the full diagram and the reasoning
behind every major decision.

## Documentation map

| Document | What's in it |
|---|---|
| [`docs/devsecops-README.md`](./docs/devsecops-README.md) | Terraform infrastructure, the full CI/CD pipeline (SAST, Trivy, Cosign, SBOM, GitOps), Kyverno policies, network policies, RBAC, and the OIDC-based authentication model |
| [`docs/devsecops-troubleshooting.md`](./docs/devsecops-troubleshooting.md) | Every infrastructure/pipeline incident hit while building the platform itself, with symptom → root cause → fix |
| [`ai-agent/docs/ai-agent-README.md`](./ai-agent/docs/ai-agent-README.md) | The agent's scope, architecture, Knowledge Base (RAG), MCP tools, CI-integrated security review, observability, and a real validated investigation result |
| [`ai-agent/docs/ai-agent-troubleshooting.md`](./ai-agent/docs/ai-agent-troubleshooting.md) | Every incident hit building the agent — from a mid-project model deprecation to a one-character hostname typo that silently broke TLS |

> The two DevSecOps documents already exist in this repo under their
> own names — rename the two links above (or move the files) to match
> if they differ from `docs/devsecops-README.md` /
> `docs/devsecops-troubleshooting.md`.

If you only read one thing before an interview or a code review: the
**readiness-probe investigation** in §7 of the agent README and in 
§1 of demo-scenarios.md is the clearest proof this agent does real multi-source 
reasoning, not pattern-matching — and the **troubleshooting logs**, in 
both parts, are the clearest proof the platform was actually operated, 
not just written once and left alone.

## Tech stack

**Infrastructure & platform:** Terraform · Azure (AKS, ACR, Key
Vault, Azure AI Foundry, Azure AI Search) · Kubernetes · Helm

**DevSecOps pipeline:** GitLab CI/CD · OIDC federation (Microsoft
Entra Workload Identity) · Semgrep/GitLab SAST · Trivy · Cosign +
Sigstore · Syft (SBOM, SPDX) · ArgoCD (GitOps) · Kyverno (policy
enforcement) · Kubernetes NetworkPolicies (zero-trust)

**Observability:** Prometheus · Grafana (dashboard-as-code via
ConfigMap) · Prometheus Pushgateway

**AI agent:** Azure AI Foundry (`gpt-4.1-mini`, GlobalStandard) ·
Model Context Protocol (Kubernetes MCP, Prometheus MCP) · Azure AI
Search (Knowledge Base / RAG) · NGINX Ingress + cert-manager /
Let's Encrypt

## Known, deliberate trade-offs

Documented in full in each component's README, but worth stating up
front: no VNet injection between Foundry and the cluster (a public,
authenticated Ingress was used instead), no Azure Monitor integration
(Prometheus already covers metrics), and the Foundry Project/Agent
themselves are provisioned outside Terraform (a current limitation of
the `azurerm` provider on this resource type, not an oversight). Each
of these is a scoping decision made for a portfolio-scale project on a
limited Azure credit — not something discovered by accident.

## Status

Actively maintained; the platform and the agent were built and
debugged iteratively, in that order, with the troubleshooting logs
kept as a permanent record of the process rather than trimmed after
the fact.

---

**Author**: Hajar Zouhair — DevOps/DevSecOps Engineer
