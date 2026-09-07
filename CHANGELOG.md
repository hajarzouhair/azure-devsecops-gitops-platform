# Changelog

## v1.0.0 — AI Incident Investigation Agent

**Summary:** Extends the existing DevSecOps platform (Terraform, AKS,
GitLab CI/CD, Kyverno, ArgoCD, Prometheus/Grafana) with an AI agent
that investigates cluster incidents by correlating live Kubernetes
state, Prometheus metrics, and the project's own documentation —
plus an AI-assisted security review integrated directly into the CI
pipeline.

This was built as a direct response to a gap in the existing
platform: the pipeline already produced plenty of signal (scan
reports, cluster events, metrics), but correlating it during an
incident was still a fully manual process.

### Added

- **Azure AI Foundry agent** (`k8s-incident-investigator`,
  `gpt-5`, `GlobalStandard`), scoped to diagnose only — no
  write access to the cluster, ever.
- **Two read-only MCP tools**: a Kubernetes MCP server and a
  Prometheus MCP server, exposed via an authenticated Ingress
  (Let's Encrypt TLS), with least-privilege RBAC.
- **RAG Knowledge Base**: Azure Blob Storage → Azure AI Search
  (indexer/index) → Knowledge Base → MCP connection into the
  Foundry Project, fully passwordless (`disableLocalAuth`, Managed
  Identity + RBAC throughout).
- **CI-integrated AI Security Review** (`ai_security_review` job):
  a dedicated, OIDC-federated identity calls the agent to analyze
  Trivy/SAST/SBOM findings and publish a structured, prioritized
  report as a pipeline artifact.
- **Agent observability**: Prometheus Pushgateway + a
  dashboard-as-code Grafana ConfigMap, tracking the AI review job's
  success rate and latency.
- **Real, non-scripted validation**: a live readiness-probe incident
  was diagnosed end-to-end by the agent, correlating six independent
  Kubernetes/Prometheus tool calls into a single structured
  root-cause report.

### Changed

- ACR authentication migrated from static admin credentials to full
  GitLab-to-Azure-AD OIDC federation — zero long-lived secrets.
- Key Vault access migrated to Entra Workload Identity.
- Fixed a real `CRITICAL` vulnerability chain
  (`CVE-2026-65182`, `CVE-2026-65905`, `CVE-2026-68525` in
  `tomcat-embed-core`) discovered by the pipeline's own Trivy scan,
  analyzed by the new AI Security Review, and resolved by pinning
  `tomcat.version` in `pom.xml`.

### Documentation

- [`devsecops-README.md`](.devsecops-README.md) — the
  DevSecOps platform architecture and decisions
- [`ai-agent/ai-agent-README.md`](./ai-agent/ai-agent-README.md) — the AI
  agent's architecture, scope, and a validated real-world result
- [`docs/devsecops-troubleshooting.md`](./docs/devsecops-troubleshooting.md)
  and
  [`ai-agent/docs/ai-agent-troubleshooting.md`](./ai-agent/docs/ai-agent-troubleshooting.md)
  — every real incident hit while building each half, kept as a
  permanent record rather than cleaned up after the fact
- [`TRADE-OFFS.md`](./TRADE-OFFS.md) — every deliberate scoping
  decision, consolidated in one place
- [`docs/ci-variables.md`](./docs/ci-variables.md) — role of every
  CI/CD variable used by the pipeline
