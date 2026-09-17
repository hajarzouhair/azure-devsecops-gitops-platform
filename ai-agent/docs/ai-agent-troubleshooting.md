# Troubleshooting — AI Agent (Knowledge Base, Infrastructure & CI/CD)

This document brings together all real incidents encountered while building the AI incident investigation agent, in chronological order of resolution. It is intentionally kept separate from the architecture README so that both documents remain independently readable.

Two parts:

- **Part 1**: Azure AI Search, Knowledge Base & Foundry
- **Part 2**: Model, network/cluster infrastructure & CI/CD pipeline

---

# PART 1 — Azure AI Search, Knowledge Base & Foundry

## 1. Terraform — Azure region unavailable

Same regional restriction already documented on the main platform project (`devsecops-troubleshooting.md`, issue #1): `westeurope` was rejecting new customers on this subscription. Fixed the same way — switched the region to `francecentral` — and provisioning continued normally. Not repeated in full detail here since the root cause and fix are identical.

---

## 2. Azure AI Search — API key authentication rejected

**Symptom**: `api-key: <key>` returned `HTTP 401 Unauthorized`, even after regenerating the key.

**Diagnosis**: The service had `disableLocalAuth: true` — API key authentication was structurally disabled, regardless of whether the key itself was valid.

**Fix**: Switched to Microsoft Entra ID token authentication:

```bash
TOKEN=$(az account get-access-token \
  --scope "https://search.azure.com/.default" \
  --query accessToken -o tsv)
```

Successfully tested with `HTTP 200` against `/indexes`.

---

## 3. RBAC — Managed identity permissions across Search, Storage & Foundry

**Context**: Both the indexer and the Knowledge Base needed correctly scoped access, and this required granting roles to two distinct managed identities in turn.

**Fixes**:

- Granted the Search Service managed identity (`4b062e98-41e2-47a2-aef2-c90f12d35de7`):
  - `Storage Blob Data Reader` on `stfhajarazuredev`
  - `Cognitive Services OpenAI User` on `aif-hajar-azure-project-dev`
- Granted the Foundry project managed identity (`7995e511-da7d-4c9a-a2a6-6500468ef404`):
  - `Search Index Data Reader`, scoped specifically to the Azure AI Search resource

**Result**: Indexing succeeded (`status: success, processed: 1, failed: 0`), and the Knowledge Base could subsequently query the index.

**Verification**:

```bash
az role assignment list --assignee-object-id "7995e511-..." \
  --scope "/subscriptions/.../searchServices/aif-hajar-azure-project-project-srch-6j0l" \
  --query "[].{Role:roleDefinitionName,PrincipalId:principalId}" -o table
```

**Lesson**: verify the exact `principalId` rather than relying only on a resource name — the Search Service identity and the Foundry project identity are easy to confuse when assigning RBAC roles.

---

## 4. Foundry Connection — Incorrect initial authentication type

**Symptom**: The Foundry connection `kb-knowledgebase-qfyjx` initially used `authType: CustomKeys`, which was incompatible with `disableLocalAuth = true` on Azure AI Search.

**Fix**: Reconfigured the connection to use:

```text
authType: ProjectManagedIdentity
audience: https://search.azure.com/
```

---

## 5. Knowledge Base MCP — HTTP 405 (false positive)

**Test**: Sent a `GET` request to the Knowledge Base MCP endpoint.

**Result**:

```text
HTTP 405, Allow: POST
```

**Interpretation**: This was not an authentication problem. The endpoint existed and was functioning; it simply expected a `POST` request. A `405` in this context was therefore a sign that the infrastructure was correctly exposed rather than broken.

---

## 6. Foundry Agent — Model rate limit

**Symptom**:

```text
Your requests to gpt-4.1-mini for gpt-4.1-mini in francecentral
have exceeded rate limit.
```

**Diagnosis**: The issue was isolated to the `gpt-4.1-mini` model deployment and was unrelated to Azure AI Search, Blob Storage, the index, the Knowledge Base, RBAC, or MCP — all of which were functioning correctly.

**Fix**: The Foundry agent was switched to `gpt-5-mini` to continue validation and operation.

> **Current state:** Terraform still provisions the `gpt-4.1-mini` deployment (`GlobalStandard`), but the Foundry agent currently uses `gpt-5-mini` because the `gpt-4.1-mini` deployment in `francecentral` is saturated/rate-limited. The Terraform deployment and the model currently selected by the Foundry agent are therefore intentionally different.

---

# PART 2 — Model, network/cluster infrastructure & CI/CD

## 7. Model deprecation during the project

**Symptom**: `terraform apply` failed twice in a row while deploying the Foundry model:

1. `SKU 'Standard' not supported in this region` for `gpt-4o-mini`.
2. After switching to `GlobalStandard`: `ServiceModelDeprecating`.

**Fix**: Performed a read-only verification before trying again:

```bash
az cognitiveservices model list -l francecentral \
  --query "[?model.name=='gpt-4.1-mini'].{version:model.version,skus:model.skus[].name}"
```

Migrated the Terraform deployment to `gpt-4.1-mini` (`GlobalStandard`, `2025-04-14`), with:

```hcl
lifecycle {
  ignore_changes = [model[0].version]
}
```

This prevents the same deployment from being blocked by future automatic Microsoft model version updates.

> **Important:** This incident documents the historical Terraform migration to `gpt-4.1-mini`. It does not mean that `gpt-4.1-mini` is currently the model used by the Foundry agent. The agent currently uses `gpt-5-mini` due to the rate-limit issue described in incident #6.

---

## 8. Azure subscription vCPU quota

**Symptom**: `ErrCode_InsufficientVCPUQuota` when attempting to add a node to the `system` node pool.

**Diagnosis**: The subscription had a regional quota of 4 vCPUs, already fully consumed by the two existing node pools.

**Decision**: No quota increase request was made, as this was considered unreliable for the free subscription. Existing capacity was optimized instead (see #9).

---

## 9. 30 pods/node limit (Azure CNI)

**Symptom**: Pods remained `Pending` with `Too many pods`, despite having explicit CPU and memory requests. The same limit later blocked the cert-manager HTTP-01 solver pod (`cm-acme-http-solver-*`), which also stayed `Pending` for the same reason.

**Diagnosis**: Azure CNI imposed a limit of 30 pods per node, which was nearly reached by system and platform workloads such as CoreDNS, konnectivity, metrics-server, CSI drivers, the Workload Identity webhook, Kyverno, and ArgoCD.

**Fixes**:

- Disabled unused ArgoCD components (`dex-server`, `notifications-controller`, `applicationset-controller`) through a version-controlled Kustomize configuration.
- Set `strategy.rollingUpdate.maxSurge: 0` on `portfolio-app`.
- Scheduled AI agent components, and later the cert-manager solver pod (via `nodeSelector`/`toleration` on `solvers[].http01.ingress.podTemplate` in the `ClusterIssuer`), on the `monitoring` node pool, which had more available capacity, instead of the `system` node pool.

---

## 10. SecretProviderClass — Forgotten placeholder, followed by a false lead

**Symptom**: Key Vault secret mounting failed with an unusual HTTP 400 response containing a generic ASP.NET error page.

**Diagnosis**: The `objectName` field still literally contained:

```text
<nom-du-secret-dans-keyvault>
```

The placeholder had never been replaced with the actual Key Vault secret name.

**False lead corrected during troubleshooting**: An attempt to dynamically resolve the client ID using:

```yaml
clientID: "${SERVICE_ACCOUNT_CLIENT_ID}"
```

failed with:

```text
AADSTS700016
```

This syntax was not supported by the installed CSI driver version. At the time of implementation, this capability was an upstream feature request rather than a delivered feature.

**Final fix**: Returned to a literal `clientID` value, which remains stable as long as the managed identity is not recreated.

---

## 11. Inconsistent ACR authentication

**Symptom**: Terraform configured:

```hcl
admin_enabled = false
```

while the pipeline still used `ACR_USERNAME` / `ACR_PASSWORD` with `docker login`.

**Fix**: Migrated completely to GitLab → Microsoft Entra ID OIDC federation:

- Dedicated App Registration
- Federated Identity Credential scoped to the exact repository and branch
- `AcrPush` role scoped only to the ACR
- Authentication through:

```bash
az login --federated-token
az acr login
```

No stored secret was required.

---

## 12. Key Vault — Incomplete Workload Identity configuration

Same Workload Identity mechanism already built and documented in depth on the main platform project, reapplied here to the agent's own Key Vault access: `oidc_issuer_enabled` was active on AKS, but `workload_identity_enabled` was missing, and the `SecretProviderClass` still contained values inherited from the previous infrastructure.

**Fix**: completed the configuration (ServiceAccount annotated with the managed identity `clientID`, projected federated token injected by `azure-wi-webhook`, exchanged for an Azure access token through Microsoft Entra ID) — removing the last dependency on static credentials for this component.

---

## 13. Kyverno blocking `:latest` images

**Symptom**: The `disallow-latest-tag` policy rejected deployments of the MCP servers.

**Additional diagnosis**: One image name was also incorrect:

```text
kubernetes-mcp-server
```

instead of the actual image name:

```text
kubernetes_mcp_server
```

with an underscore.

**Fix**:

- Retrieved the actual available tags using `skopeo list-tags`
- Pinned deployments to real image tags
- Corrected the image name

---

## 14. Prometheus MCP server stuck in stdio mode

**Symptom**: The pod repeatedly terminated successfully with:

```text
Completed
```

rather than entering `CrashLoopBackOff`.

**Diagnosis**: The default transport mode was `stdio`. The pinned image version (`1.0.4`) did not yet support environment variables for forcing HTTP transport.

**Fix**: Updated to a version supporting HTTP transport, after verifying that the required tag actually existed.

---

## 15. Azure Load Balancer health probe incompatible with NGINX

**Symptom**: External traffic timed out, while internal access through the NodePort worked correctly.

**Diagnosis**: Azure Load Balancer `DipAvailability` metrics showed approximately 20% successful probes.

The health probe was requesting `/` over HTTP, while NGINX returned `404` on `/` because there was no matching Ingress rule for that path. Azure therefore considered the backend unhealthy.

**Fix**: Redirected the health probe to `/healthz` using:

```yaml
service.beta.kubernetes.io/azure-load-balancer-health-probe-request-path
```

---

## 16. TLS certificate not associated — hostname typo

**Symptom**: The TLS handshake continued to serve the default self-signed NGINX certificate, even though a valid Let's Encrypt certificate had already been issued.

**Diagnosis**: A manual edit had introduced a mismatch between `spec.rules[].host` and `spec.tls[].hosts` — one dot had been replaced with a hyphen. NGINX associates certificates through exact SNI hostname matching, so the mismatch prevented the correct certificate from being selected.

**Diagnosis command** (useful in general for isolating SNI/certificate mismatches):

```bash
openssl s_client -connect <ip>:443 -servername <host-attendu> </dev/null \
  | openssl x509 -noout -issuer
```

**Fix**: Corrected the hostname inconsistency between the two fields.

---

## 17. `ai_security_review` job — four consecutive failures

### 17.1 YAML indentation error

An indentation error in `.gitlab-ci.yml` caused `artifacts.paths` to be incorrectly aligned. This blocked the job before the AI logic itself could run.

### 17.2 Incorrect authentication token

The raw GitLab OIDC token was sent directly as a `Bearer token` to Foundry. This was incorrect: the GitLab OIDC token is used to prove identity for a federated exchange; it is not itself the final access token for Foundry.

**Fix**: Added an explicit `client_credentials` + `client_assertion` exchange against `login.microsoftonline.com` before calling Foundry.

### 17.3 API version drift

The API version `2025-05-01` was rejected with `UnsupportedApiVersion` on `/agents/{name}/endpoint/protocols/openai/responses`. The correct value, confirmed against Microsoft's official example for this specific endpoint, was `api-version=v1`.

### 17.4 `context_length_exceeded`

The raw Trivy, SAST, and SBOM reports were sent directly to the model, exceeding its context window.

**Fix**:

- Trivy reports were filtered to HIGH/CRITICAL vulnerabilities.
- SAST and SBOM reports were truncated to essential fields.
- The resulting summaries were sent to the agent instead of the complete raw reports.

**Result**: Once all four issues were fixed, the pipeline successfully analyzed a real security result:

- Three **CRITICAL** CVEs were identified in: `org.apache.tomcat.embed:tomcat-embed-core 10.1.55`
- CVEs: `CVE-2026-65182`, `CVE-2026-65905`, `CVE-2026-68525`
- Fixed version: `10.1.58`

The findings were automatically transformed into a structured and prioritized report.

---

## 18. RBAC gaps discovered under real operating conditions

Three read-only permissions were missing and were discovered only when the agent actually needed them during an investigation:

- `namespaces` — cluster-wide listing
- `pods.metrics.k8s.io` — live metrics
- `endpoints` — Service routing verification during the investigation of a broken readiness probe

**Fix**: Consolidated these permissions into a single broader `Role` / `ClusterRole`, while keeping the entire access surface strictly read-only.

The resulting RBAC policy covers the current read-only surface required for Kubernetes incident diagnosis, avoiding incremental permission discovery during a live demonstration.

---

## 19. Grafana dashboard lost after every restart/rebuild

Same underlying "dashboard as code" fix already applied on the main platform project, reapplied here to the agent's own panels: a dashboard imported through the Grafana UI is stored in Grafana's internal SQLite database and doesn't survive the pod lifecycle.

**Fix**: converted the dashboard to a version-controlled `ConfigMap` labelled `grafana_dashboard: "1"`, automatically loaded by the Grafana sidecar. The dashboard, including the agent-specific panels, now survives a full `terraform destroy` / `terraform apply` cycle — confirmed through testing.

---

## 20. `ai_security_review` job never executed — chained dependencies

**Symptom**: No agent metrics appeared anywhere, with no visible error.

**Diagnosis**: The `push_to_acr` job had failed because of a temporary network timeout during `az acr login`. GitLab's chained `needs` dependencies were:

```text
sign_and_sbom → push_to_acr
ai_security_review → sign_and_sbom
```

Therefore, GitLab never executed a job whose required dependency had failed. `ai_security_review` appeared grey (`skipped`) in the pipeline and had never actually run. This was not a script bug.

**Fix**: Simply rerunning the failed `push_to_acr` job allowed the remaining dependency chain to execute normally.

---

## 21. Metrics push silently failing

**Symptom**: The `ai_security_review` job succeeded (`STATUS: 200`, `Report generated successfully`), but no metrics ever appeared in Pushgateway.

**Diagnosis**: The `push_metrics` function did not log anything when environment variables were missing and simply returned. It also did not log successful pushes. As a result, a CI job could succeed while the metrics push had silently been skipped, with no evidence showing what had happened.

**Fix**: Added explicit logs such as `PUSH METRICS STATUS: ...` to every branch of the function, including both success and failure paths. There is now no silent failure zone in this step.

---

## 22. Basic Auth password desynchronized after rotation

**Symptom**: After regenerating the Ingress Basic Auth password, an external `curl` request to Pushgateway returned `401 Unauthorized`, while internal access through `port-forward` continued to work.

**Diagnosis**: The same password was used in four distinct locations that had to remain synchronized:

1. Kubernetes secret: `mcp-basic-auth`
2. GitLab variable: `PUSHGATEWAY_AUTH`
3. Authorization header on the Foundry MCP tool: `kubernetes-cluster`
4. Authorization header on the second Foundry MCP tool: `prometheus-metrics`

The password rotation had only been applied to some of these locations.

**Fix**: Regenerated the password and propagated the new value to all required locations.

Verification:

```bash
htpasswd -vb <(kubectl get secret mcp-basic-auth -n ai-agent -o jsonpath='{.data.auth}' | base64 -d) mcp-agent "<mot-de-passe>"
```

**Side effect discovered afterwards**: Once Pushgateway authentication was resynchronized, the agent itself started returning `401 Unauthorized` when accessing its Kubernetes MCP tool — same cause: the Authorization header configured for the Foundry tool still contained the old password. The header was updated for both Foundry tools.

**Known limitation / roadmap item**: The shared static Basic Auth credential currently exists in four different locations and has no automated rotation mechanism. A stronger long-term design would use dedicated credentials per consumer or a managed secret rotation mechanism rather than relying on manual synchronization after every password rotation.

---

# Consolidated Final State

| Component | Status |
|---|---|
| Blob Storage / Data Source / Indexer / Index (365 documents) | ✅ |
| Knowledge Base + MCP connection (ProjectManagedIdentity) | ✅ |
| Foundry Agent (`gpt-5-mini`) | ✅ |
| Kubernetes & Prometheus MCP servers (read-only RBAC) | ✅ |
| Ingress + Let's Encrypt TLS (production) | ✅ |
| ACR authentication (OIDC, zero secrets) | ✅ |
| Key Vault (Workload Identity) | ✅ |
| CI `ai_security_review` job (dedicated identity, report summarization) | ✅ |
| Agent observability (Pushgateway → Prometheus → Grafana) | ✅ |
| Persistent Grafana dashboard (ConfigMap as code) | ✅ |
| Readiness probe demonstration scenario (multi-source investigation) | ✅ |

> **Model note:** `gpt-4.1-mini` remains provisioned through Terraform as a `GlobalStandard` deployment, but the Foundry agent currently uses `gpt-5-mini` because the `gpt-4.1-mini` deployment in `francecentral` is rate-limited.

---

# Lessons Learned

1. **A Terraform error can originate from an Azure platform restriction**, not necessarily from a configuration mistake. Check regions, quotas, and policies before looking for a syntax or code-level problem.

2. **`disableLocalAuth=true` requires an Entra ID / RBAC architecture end to end.** API keys are no longer an option; this is not simply a matter of following a security best practice.

3. **Always verify the exact `principalId`**, rather than relying only on a resource name, before assigning an RBAC role. Different managed identities — such as the Search Service identity and the Foundry project identity — are easy to confuse.

4. **An unexpected HTTP status code is not always a failure.** A `405` on an MCP endpoint can indicate that the endpoint exists and is correctly exposed but that the wrong HTTP method was used.

5. **Separate diagnostic layers.** Model rate limits, subscription vCPU quotas, and per-node pod limits are completely independent Azure constraints that can produce superficially similar symptoms ("it doesn't work"). Isolating the affected layer before applying a fix prevents changing the wrong component.

6. **Never rely on unverified syntax, even when similar syntax is documented elsewhere.** The `${SERVICE_ACCOUNT_CLIENT_ID}` attempt in #10 and the Foundry API version changes in #17 demonstrate that a read-only verification before applying a change is cheaper than repeated failed deployments.

7. **A successful CI job does not prove that every internal step actually succeeded.** A silent `return` on partial failure can hide a problem across multiple pipeline runs. Every critical branch should log its result explicitly, including successful execution.

8. **A shared secret across multiple consumers creates a synchronization risk rather than simplifying security.** Every rotation must be propagated to every location where the credential is used, or replaced with dedicated credentials per consumer whenever reasonably possible.

9. **Keep infrastructure state and application configuration conceptually separate.** Terraform can provision a model deployment while the Foundry agent may use a different deployment. The documentation should clearly distinguish what is infrastructure-managed from what is currently selected at the application/agent level.

10. **Version-control operational configuration whenever possible.** Dashboards, policies, routing configuration, and Kubernetes resources should be represented as code so that rebuilding the environment does not require undocumented manual steps.
