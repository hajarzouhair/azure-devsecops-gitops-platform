# Troubleshooting — AI Agent (Knowledge Base, Infrastructure & CI/CD)

This document brings together all real incidents encountered while building the AI incident investigation agent, in chronological order of resolution. It is intentionally kept separate from the architecture README so that both documents remain independently readable.

Two parts:

- **Part 1**: Azure AI Search, Knowledge Base & Foundry
- **Part 2**: Model, network/cluster infrastructure & CI/CD pipeline

---

# PART 1 — Azure AI Search, Knowledge Base & Foundry

## 1. Terraform — Azure region unavailable

**Context**: Initial infrastructure provisioning in `westeurope`.

**Symptom**:

```text
RequestDisallowedByAzure:
The selected region is currently not accepting new customers.
```

**Diagnosis**: Azure imposed a restriction on the region for this subscription; this was not a Terraform syntax error.

**Fix**: Changed the region from `westeurope` to `francecentral`. Provisioning then continued normally.

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

## 3. Azure AI Search — Search Service permissions

**Context**: The indexer needed access to Blob Storage and Azure AI processing capabilities.

**Fix**: Granted the Search Service managed identity (`4b062e98-41e2-47a2-aef2-c90f12d35de7`) the following roles:

- `Storage Blob Data Reader` on `stfhajarazuredev`
- `Cognitive Services OpenAI User` on `aif-hajar-azure-project-dev`

**Result**: Indexing succeeded — `status: success, processed: 1, failed: 0`.

---

## 4. Knowledge Base — Foundry project permission

**Fix**: Granted the `Search Index Data Reader` role to the Foundry project managed identity (`7995e511-da7d-4c9a-a2a6-6500468ef404`), scoped specifically to the Azure AI Search resource.

**Verification**:

```bash
az role assignment list --assignee-object-id "7995e511-..." \
  --scope "/subscriptions/.../searchServices/aif-hajar-azure-project-project-srch-6j0l" \
  --query "[].{Role:roleDefinitionName,PrincipalId:principalId}" -o table
```

---

## 5. Foundry Connection — Incorrect initial authentication type

**Symptom**: The Foundry connection `kb-knowledgebase-qfyjx` initially used `authType: CustomKeys`, which was incompatible with `disableLocalAuth = true` on Azure AI Search.

**Fix**: Reconfigured the connection to use:

```text
authType: ProjectManagedIdentity
audience: https://search.azure.com/
```

---

## 6. Knowledge Base MCP — HTTP 405 (false positive)

**Test**: Sent a `GET` request to the Knowledge Base MCP endpoint.

**Result**:

```text
HTTP 405, Allow: POST
```

**Interpretation**: This was not an authentication problem. The endpoint existed and was functioning; it simply expected a `POST` request.

A `405` in this context was therefore a sign that the infrastructure was correctly exposed rather than broken.

---

## 7. Foundry Agent — Model rate limit

**Symptom**:

```text
Your requests to gpt-4.1-mini for gpt-4.1-mini in francecentral
have exceeded rate limit.
```

**Diagnosis**: The issue was isolated to the `gpt-4.1-mini` model deployment and was unrelated to Azure AI Search, Blob Storage, the index, the Knowledge Base, RBAC, or MCP — all of which were functioning correctly.

**Fix**: The Foundry agent was switched to `gpt-5-mini` to continue validation and operation.

> **Current state:** Terraform still provisions the `gpt-4.1-mini` deployment (`GlobalStandard`), but the Foundry agent currently uses `gpt-5-mini` because the `gpt-4.1-mini` deployment in `francecentral` is saturated/rate-limited. The Terraform deployment and the model currently selected by the Foundry agent are therefore intentionally different.

---

## 8–9. Final validation and grounding

Two tests confirmed that the complete chain was working correctly:

- An open-ended question about the Knowledge Base content allowed the agent to correctly list the indexed documents.
- A targeted question about the Azure region incident described in section 1 was correctly retrieved and returned by the agent from `troubleshooting.md` itself — proving that retrieval was actually working, rather than relying only on the model's general knowledge.

---

# PART 2 — Model, network/cluster infrastructure & CI/CD

## 10. Model deprecation during the project

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

> **Important:** This incident documents the historical Terraform migration to `gpt-4.1-mini`. It does not mean that `gpt-4.1-mini` is currently the model used by the Foundry agent. The agent currently uses `gpt-5-mini` due to the rate-limit issue described in incident #7.

---

## 11. Azure subscription vCPU quota

**Symptom**: `ErrCode_InsufficientVCPUQuota` when attempting to add a node to the `system` node pool.

**Diagnosis**: The subscription had a regional quota of 4 vCPUs, already fully consumed by the two existing node pools.

**Decision**: No quota increase request was made, as this was considered unreliable for the free subscription. Existing capacity was optimized instead (see #12).

---

## 12. 30 pods/node limit (Azure CNI)

**Symptom**: Pods remained `Pending` with `Too many pods`, despite having explicit CPU and memory requests.

**Diagnosis**: Azure CNI imposed a limit of 30 pods per node, which was nearly reached by system and platform workloads such as CoreDNS, konnectivity, metrics-server, CSI drivers, the Workload Identity webhook, Kyverno, and ArgoCD.

**Fixes**:

- Disabled unused ArgoCD components (`dex-server`, `notifications-controller`, `applicationset-controller`) through a version-controlled Kustomize configuration.
- Set `strategy.rollingUpdate.maxSurge: 0` on `portfolio-app`.
- Scheduled AI agent components on the `monitoring` node pool, which had more available capacity, instead of the `system` node pool.

---

## 13. SecretProviderClass — Forgotten placeholder, followed by a false lead

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

## 14. Inconsistent ACR authentication

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

## 15. Key Vault — Incomplete Workload Identity configuration

**Symptom**: `oidc_issuer_enabled` was active on AKS, but `workload_identity_enabled` was missing, while the `SecretProviderClass` still contained values inherited from the previous infrastructure.

**Fix**: Completed the Microsoft Entra Workload Identity configuration:

- ServiceAccount annotated with the managed identity `clientID`
- Automatic injection of a projected federated token by `azure-wi-webhook`
- Exchange of that token for an Azure access token through Microsoft Entra ID
- No secret stored inside the cluster

This replaced the previous authentication dependency on static credentials.

---

## 16. Complete absence of an Ingress controller

**Symptom**:

```bash
kubectl get ingressclass
```

returned no resources.

**Fix**: Installed the NGINX Ingress Controller through Helm and scheduled it on the `monitoring` node pool.

The controller provisions an Azure Load Balancer, introducing an additional hourly infrastructure cost that must be monitored.

---

## 17. Kyverno blocking `:latest` images

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

## 18. Prometheus MCP server stuck in stdio mode

**Symptom**: The pod repeatedly terminated successfully with:

```text
Completed
```

rather than entering `CrashLoopBackOff`.

**Diagnosis**: The default transport mode was `stdio`. The pinned image version (`1.0.4`) did not yet support environment variables for forcing HTTP transport.

**Fix**: Updated to a version supporting HTTP transport, after verifying that the required tag actually existed.

---

## 19. Azure Load Balancer health probe incompatible with NGINX

**Symptom**: External traffic timed out, while internal access through the NodePort worked correctly.

**Diagnosis**: Azure Load Balancer `DipAvailability` metrics showed approximately 20% successful probes.

The health probe was requesting `/` over HTTP, while NGINX returned `404` on `/` because there was no matching Ingress rule for that path. Azure therefore considered the backend unhealthy.

**Fix**: Redirected the health probe to `/healthz` using:

```yaml
service.beta.kubernetes.io/azure-load-balancer-health-probe-request-path
```

---

## 20. TLS certificate not associated — hostname typo

**Symptom**: The TLS handshake continued to serve the default self-signed NGINX certificate, even though a valid Let's Encrypt certificate had already been issued.

**Diagnosis**: A manual edit had introduced a mismatch between:

```yaml
spec.rules[].host
```

and:

```yaml
spec.tls[].hosts
```

One dot had been replaced with a hyphen.

NGINX associates certificates through exact SNI hostname matching, so the mismatch prevented the correct certificate from being selected.

**Diagnosis command**:

```bash
openssl s_client -connect <ip>:443 -servername <host-attendu> </dev/null \
  | openssl x509 -noout -issuer
```

**Fix**: Corrected the hostname inconsistency between the two fields.

---

## 21. cert-manager solver pod stuck in Pending

**Symptom**: The HTTP-01 challenge never completed because:

```text
cm-acme-http-solver-*
```

remained `Pending`.

**Diagnosis**: The same 30-pods-per-node limit described in incident #12 had been reached.

**Fix**: Added a `nodeSelector` / `toleration` targeting the `monitoring` node pool directly in:

```yaml
solvers[].http01.ingress.podTemplate
```

of the `ClusterIssuer`.

---

## 22. `ai_security_review` job — four consecutive failures

### 22.1 YAML indentation error

An indentation error in `.gitlab-ci.yml` caused:

```text
artifacts.paths
```

to be incorrectly aligned.

This blocked the job before the AI logic itself could run.

### 22.2 Incorrect authentication token

The raw GitLab OIDC token was sent directly as a `Bearer token` to Foundry.

This was incorrect: the GitLab OIDC token is used to prove identity for a federated exchange; it is not itself the final access token for Foundry.

**Fix**: Added an explicit `client_credentials` + `client_assertion` exchange against:

```text
login.microsoftonline.com
```

before calling Foundry.

### 22.3 API version drift

The following API version:

```text
2025-05-01
```

was rejected with:

```text
UnsupportedApiVersion
```

on:

```text
/agents/{name}/endpoint/protocols/openai/responses
```

The correct value, confirmed against Microsoft's official example for this specific endpoint, was:

```text
api-version=v1
```

### 22.4 `context_length_exceeded`

The raw Trivy, SAST, and SBOM reports were sent directly to the model, exceeding its context window.

**Fix**:

- Trivy reports were filtered to HIGH/CRITICAL vulnerabilities.
- SAST and SBOM reports were truncated to essential fields.
- The resulting summaries were sent to the agent instead of the complete raw reports.

**Result**: Once all four issues were fixed, the pipeline successfully analyzed a real security result:

- Three **CRITICAL** CVEs were identified in:
  `org.apache.tomcat.embed:tomcat-embed-core 10.1.55`
- CVEs:
  - `CVE-2026-65182`
  - `CVE-2026-65905`
  - `CVE-2026-68525`
- Fixed version:
  `10.1.58`

The findings were automatically transformed into a structured and prioritized report.

---

## 23. RBAC gaps discovered under real operating conditions

Three read-only permissions were missing and were discovered only when the agent actually needed them during an investigation:

- `namespaces` — cluster-wide listing
- `pods.metrics.k8s.io` — live metrics
- `endpoints` — Service routing verification during the investigation of a broken readiness probe

**Fix**: Consolidated these permissions into a single broader `Role` / `ClusterRole`, while keeping the entire access surface strictly read-only.

The resulting RBAC policy covers the current read-only surface required for Kubernetes incident diagnosis, avoiding incremental permission discovery during a live demonstration.

---

## 24. Grafana dashboard lost after every restart/rebuild

**Symptom**: The Grafana dashboard had to be manually re-imported after every Grafana pod restart or cluster rebuild.

**Diagnosis**: A dashboard imported through the Grafana UI is stored in Grafana's internal database (SQLite by default). It is therefore not version-controlled and is not guaranteed to survive the pod lifecycle.

**Fix**: Converted the dashboard to configuration-as-code using a `ConfigMap` labelled:

```yaml
grafana_dashboard: "1"
```

The file:

```text
grafana-dashboard-configmap.yaml
```

is version-controlled in Git and automatically loaded by the Grafana sidecar of the `kube-prometheus-stack` chart.

The dashboard, including the new agent-specific panels, now survives a complete:

```text
terraform destroy
terraform apply
```

cycle, confirmed through testing.

---

## 25. `ai_security_review` job never executed — chained dependencies

**Symptom**: No agent metrics appeared anywhere, with no visible error.

**Diagnosis**: The `push_to_acr` job had failed because of a temporary network timeout during:

```bash
az acr login
```

GitLab's chained `needs` dependencies were:

```text
sign_and_sbom → push_to_acr
ai_security_review → sign_and_sbom
```

Therefore, GitLab never executed a job whose required dependency had failed.

`ai_security_review` appeared grey (`skipped`) in the pipeline and had never actually run. This was not a script bug.

**Fix**: Simply rerunning the failed `push_to_acr` job allowed the remaining dependency chain to execute normally.

---

## 26. Metrics push silently failing

**Symptom**: The `ai_security_review` job succeeded:

```text
STATUS: 200
Report generated successfully
```

but no metrics ever appeared in Pushgateway.

**Diagnosis**: The `push_metrics` function did not log anything when environment variables were missing and simply returned. It also did not log successful pushes.

As a result, a CI job could succeed while the metrics push had silently been skipped, with no evidence showing what had happened.

**Fix**: Added explicit logs such as:

```text
PUSH METRICS STATUS: ...
```

to every branch of the function, including both success and failure paths.

There is now no silent failure zone in this step.

---

## 27. Basic Auth password desynchronized after rotation

**Symptom**: After regenerating the Ingress Basic Auth password, an external `curl` request to Pushgateway returned:

```text
401 Unauthorized
```

while internal access through `port-forward` continued to work.

**Diagnosis**: The same password was used in four distinct locations that had to remain synchronized:

1. Kubernetes secret:
   ```text
   mcp-basic-auth
   ```
2. GitLab variable:
   ```text
   PUSHGATEWAY_AUTH
   ```
3. Authorization header configured on the Foundry MCP tool:
   ```text
   kubernetes-cluster
   ```
4. Authorization header configured on the second Foundry MCP tool:
   ```text
   prometheus-metrics
   ```

The password rotation had only been applied to some of these locations.

**Fix**: Regenerated the password and propagated the new value to all required locations.

Verification:

```bash
htpasswd -vb <(kubectl get secret mcp-basic-auth -n ai-agent -o jsonpath='{.data.auth}' | base64 -d) mcp-agent "<mot-de-passe>"
```

**Side effect discovered afterwards**: Once Pushgateway authentication was resynchronized, the agent itself started returning:

```text
401 Unauthorized
```

when accessing its Kubernetes MCP tool.

The cause was the same: the Authorization header configured for the Foundry tool still contained the old password.

The header was updated for both Foundry tools.

**Known limitation / roadmap item**: The shared static Basic Auth credential currently exists in four different locations and has no automated rotation mechanism.

A stronger long-term design would use dedicated credentials per consumer or a managed secret rotation mechanism rather than relying on manual synchronization after every password rotation.

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

6. **Never rely on unverified syntax, even when similar syntax is documented elsewhere.** The `${SERVICE_ACCOUNT_CLIENT_ID}` attempt in #13 and the Foundry API version changes in #22 demonstrate that a read-only verification before applying a change is cheaper than repeated failed deployments.

7. **A successful CI job does not prove that every internal step actually succeeded.** A silent `return` on partial failure can hide a problem across multiple pipeline runs. Every critical branch should log its result explicitly, including successful execution.

8. **A shared secret across multiple consumers creates a synchronization risk rather than simplifying security.** Every rotation must be propagated to every location where the credential is used, or replaced with dedicated credentials per consumer whenever reasonably possible.

9. **Keep infrastructure state and application configuration conceptually separate.** Terraform can provision a model deployment while the Foundry agent may use a different deployment. The documentation should clearly distinguish what is infrastructure-managed from what is currently selected at the application/agent level.

10. **Version-control operational configuration whenever possible.** Dashboards, policies, routing configuration, and Kubernetes resources should be represented as code so that rebuilding the environment does not require undocumented manual steps.
