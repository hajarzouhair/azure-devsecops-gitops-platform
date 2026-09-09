# Trade-offs — Deliberate Scoping Decisions

This file consolidates every deliberate trade-off made across this
project — decisions that simplify the architecture for a portfolio
project on a limited Azure credit, made consciously rather than
discovered by accident. Each is cross-referenced to where it's
mentioned in more detail elsewhere.

## Networking

**Public authenticated Ingress instead of Foundry VNet injection.**
Azure AI Foundry is a managed service outside the cluster's VNet. The
correct production approach would be VNet injection for private
connectivity between Foundry and the Kubernetes/Prometheus MCP
servers. Instead, the MCP servers are exposed via an NGINX Ingress
protected by Basic Auth + Let's Encrypt TLS. Accepted for a
portfolio-scale project; VNet injection is listed in the agent
README's roadmap.

**`GlobalStandard` SKU for the Foundry model deployment.** The
originally planned `Standard` SKU (regional, data guaranteed to stay
in-region) was rejected by Azure in `francecentral`, and the
originally planned model (`gpt-4o-mini`) was later deprecated
mid-project. `gpt-5-mini GlobalStandard` was used instead, but does not guarantee the request is processed
within a specific region. Acceptable here: no data residency
requirement for this project. See `ai-agent/docs/ai-agent-troubleshooting.md`
§10.

**Shared static Basic Auth credential across four consumers.** The
same password protects the Ingress and is independently referenced in
the GitLab CI/CD variable, the Kubernetes secret, and two separate MCP
tool configurations in the Foundry portal. There is no automatic
rotation and no single source of truth — a manual credential change
must be propagated to all four places by hand (learned the hard way,
see `docs/ai-agent-troubleshooting.md` §27). Roadmap: a secret per
consumer, or an automated rotation/vault mechanism.

## Azure resource management

**The Foundry Project and Agent are not Terraform-managed.** Only the
underlying Cognitive Services account and model deployment are
provisioned via Terraform; the Project and Agent themselves were
created through the Azure portal. This is a current limitation of the
`azurerm` provider on this resource model, not an oversight — see
`ai-agent/docs/ai-agent-README.md` §4.

**No Azure Monitor / Log Analytics integration.** Prometheus already
covers the metrics the agent needs; adding Azure Monitor would
duplicate both data and cost without a clear benefit at this scale.

## Agent scope and safety

**Diagnose-only, no human-in-the-loop remediation.** The agent can
investigate and recommend, but never executes a fix — not even with
approval. A human-in-the-loop flow (agent proposes → human approves →
automated commit/PR) is documented as a roadmap item, not built,
because it introduces a much larger safety surface than a portfolio
project needs to prove out first.

**No observability of interactive Foundry chat usage.** Only
CI-triggered agent calls (`ai_security_review`) are currently
monitored via the Pushgateway. Full coverage of interactive portal
conversations would require Application Insights — left as roadmap.

## Infrastructure capacity (free-tier subscription constraints)

**No dedicated node pool added for the AI agent's components.** The
free-tier subscription's 4-vCPU regional quota made adding a node
pool impossible (see `docs/ai-agent-troubleshooting.md` §11). Instead,
all agent components (MCP servers, Pushgateway, cert-manager's solver
pods, the ingress controller itself) were deliberately scheduled on
the existing, underused `monitoring` node pool rather than the
`system` pool. This trades some workload isolation for staying within
quota.

**`maxSurge: 0` on `portfolio-app`'s rollout strategy.** Chosen to
avoid needing one extra pod slot during deployments, given the
cluster's tight pod-per-node ceiling (Azure CNI's 30-pods-per-node
limit). Trade-off: a brief moment of unavailability during rollouts,
instead of a zero-downtime deployment.

## Status of previously-open items

**Trivy blocking gate (`|| true` on the exit code check).** This was a
temporary bypass used to capture a real CVE finding for the AI
Security Review without interrupting iteration. Status: **resolved**
— the underlying vulnerability (`tomcat-embed-core` CVEs) was fixed at
the dependency level, and the bypass was removed to restore real
blocking behavior. Kept here as a record of the decision, since the
bypass existed for a real reason and wasn't just an oversight left in
place.
