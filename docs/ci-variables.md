# GitLab CI/CD Variables — Reference

This file documents the role of every CI/CD variable used by the
pipeline. No values are included — only their purpose, which job
consumes them, and why they're masked/protected.

| Variable | Used by | Role |
|---|---|---|
| `ACR_LOGIN_SERVER` | `build`, `push_to_acr`, `sign_and_sbom` | Hostname of the Azure Container Registry (e.g. `acrhajarazureprojectdev.azurecr.io`), used to construct the full image tag pushed and pulled throughout the pipeline. |
| `AZURE_CLIENT_ID` | `push_to_acr`, `sign_and_sbom` | Client ID of the Azure AD App Registration federated with GitLab OIDC (`AZURE_ID_TOKEN`), holding the `AcrPush` role scoped to the ACR only. No client secret — authentication is via federated token exchange. |
| `AZURE_TENANT_ID` | `push_to_acr`, `sign_and_sbom`, `ai_security_review` | Azure AD tenant ID, shared across both federated identities used in this pipeline (ACR push and AI review). |
| `AI_REVIEW_CLIENT_ID` | `ai_security_review` | Client ID of a **separate**, dedicated Azure AD identity holding the `Foundry Agent Consumer` role scoped to the Foundry Project only — deliberately isolated from `AZURE_CLIENT_ID` (least privilege between unrelated workflows: registry push vs. AI agent invocation). |
| `FOUNDRY_PROJECT_ENDPOINT` | `ai_security_review` | Base REST endpoint of the Azure AI Foundry Project, used to build the Responses API URL the job calls to reach the agent. |
| `FOUNDRY_AGENT_NAME` | `ai_security_review` | Identifier of the Foundry agent (`k8s-incident-investigator`) that the job invokes to analyze the Trivy/SAST/SBOM reports. |
| `GIT_PUSH_TOKEN` | `update_manifest` | GitLab token allowing the pipeline to commit and push the updated image tag back to `k8s/overlays/dev/kustomization.yaml` — the step that closes the GitOps loop (build → new tag → commit → push → ArgoCD sync), without manual intervention. |
| `PUSHGATEWAY_URL` | `ai_security_review` | External URL (via the project's Ingress) of the Prometheus Pushgateway, where the job pushes its own success/failure and duration metrics for Grafana. |
| `PUSHGATEWAY_AUTH` | `ai_security_review` | Basic Auth credentials (`user:password`) matching the Ingress's `mcp-basic-auth` secret, required to authenticate the metrics push to `PUSHGATEWAY_URL`. |

## Notes on masking

All variables above are marked **Protected** (only available on protected
branches/tags) and **Masked** (hidden from job logs) except
`PUSHGATEWAY_URL`, which is a plain URL with no embedded credential and
therefore doesn't need masking — only protection.

## A known limitation worth stating explicitly

`PUSHGATEWAY_AUTH` and the Ingress's `mcp-basic-auth` Kubernetes secret
must stay manually synchronized, and that same password is also
referenced independently in two places inside the Foundry portal (the
`kubernetes-cluster` and `prometheus-metrics` MCP tool configurations).
There is currently no automatic rotation or single source of truth for
this credential across all four consumers — see `TRADE-OFFS.md`.
