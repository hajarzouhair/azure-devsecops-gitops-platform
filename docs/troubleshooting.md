# Troubleshooting Log

Real issues encountered while building this project, with root causes and fixes — kept as a record of actual debugging work rather than a polished "everything worked first try" narrative.

---

## 1. Azure Region Restriction

**Symptom**: `terraform apply` failed creating the Virtual Network with `RequestDisallowedByAzure: The selected region is currently not accepting new customers.`

**Diagnosis**: the subscription was authenticated correctly, but `westeurope` was not accepting new customers for this specific free-trial subscription.

**Fix**: deployment region changed to `francecentral`.

**Lesson**: free-trial Azure subscriptions can have per-region restrictions independent of the account itself — always confirm region availability before assuming a config error.

---

## 2. Subnet Resource Not Found During Terraform Polling

**Symptom**: Terraform reported `ResourceNotFound` for a subnet while polling its provisioning state, even though Azure CLI confirmed the subnet existed with `ProvisioningState: Succeeded`.

**Diagnosis**: `terraform state list` showed the resource group and VNet, but not the subnet — it existed in Azure but was missing from Terraform's state.

**Fix**: imported the existing subnet into state with `terraform import azurerm_subnet.aks <resource-id>`.

**Lesson**: a resource existing in the cloud provider does not guarantee it exists in Terraform's state — state and reality can diverge, especially after partial applies.

---

## 3. Terraform Provider Binary Exceeding GitLab File Size Limit

**Symptom**: `git push` rejected — a 223 MiB blob exceeded GitLab's 100 MiB limit.

**Diagnosis**: the blob was `terraform/.terraform/providers/.../terraform-provider-azurerm_v3.117.1_x5` — the AzureRM provider binary downloaded automatically by `terraform init`. `.terraform/` and state files were not yet in `.gitignore`.

**Fix**: added `.terraform/`, `*.tfstate*`, `*.tfvars*` to `.gitignore`; removed the already-tracked files with `git rm -r --cached`; amended the unpushed commit. `.terraform.lock.hcl` was kept under version control (it locks provider versions/checksums, unlike the binaries themselves).

**Lesson**: `.gitignore` only prevents *future* additions — files already committed need `git rm --cached` (or history rewriting if already pushed) in addition to the ignore rule.

---

## 4. AKS VM Size Not Allowed for Subscription

**Symptom**: `terraform apply` failed creating the AKS cluster: `The VM size of Standard_B2s is not allowed in your subscription in location 'francecentral'.`

**Diagnosis**: the free-trial subscription restricts available VM SKUs per region to an allow-list; `Standard_B2s` (a common, well-documented AKS size) wasn't on it for this subscription/region combination.

**Fix**: switched the node pool `vm_size` to `Standard_D2ads_v7`, the smallest SKU present in Azure's returned allow-list.

**Lesson**: don't assume a "standard" or widely-documented VM size is universally available — free-trial subscriptions can restrict SKUs independently of quota.

---

## 5. kubectl Using K3s Instead of AKS

**Symptom**: after `az aks get-credentials`, `kubectl get nodes` failed with `permission denied: /etc/rancher/k3s/k3s.yaml`.

**Diagnosis**: the WSL environment already had K3s installed, which had replaced `/usr/local/bin/kubectl` with a symlink to the K3s binary (`kubectl -> k3s`), so `kubectl` was reading K3s's kubeconfig instead of the AKS one Azure CLI had written to `~/.kube/config`.

**Fix**: installed the official Kubernetes `kubectl` client and replaced the symlink, without touching the K3s installation itself.

**Lesson**: `kubectl` is only a CLI client talking to whichever cluster its active context/kubeconfig points to — it isn't tied to any specific cluster. A tool that ships its own `kubectl` symlink can silently redirect all cluster interactions.

---

## 6. AKS OIDC Issuer Feature Cannot Be Disabled

**Symptom**: `terraform apply` failed updating the AKS cluster (triggered by adding the Key Vault CSI provider add-on): `OIDCIssuerFeatureCannotBeDisabled`. The plan showed `oidc_issuer_enabled = true -> null`.

**Diagnosis**: Azure enables the OIDC issuer by default on new clusters; because `aks.tf` never declared this attribute, Terraform's implicit default (unset) caused it to attempt disabling a feature Azure won't allow turning off.

**Fix**: declared `oidc_issuer_enabled = true` explicitly, matching actual state.

**Lesson**: cloud providers can enable features by default independently of what's declared in Terraform — an unset attribute is not neutral if the provider has its own default.

---

## 7. CSI Driver Failing to Authenticate — Multiple Managed Identities

**Symptom**: a test pod mounting a Key Vault secret stayed stuck in `ContainerCreating`, with `FailedMount`: `ManagedIdentityCredential: ... Multiple user assigned identities exist, please specify the clientId`.

**Diagnosis**: the AKS cluster has more than one managed identity attached (the kubelet identity for ACR pulls, and a separate identity auto-created by the Key Vault CSI add-on) — `useVMManagedIdentity: "true"` alone was ambiguous about which to use.

**Fix**: retrieved the CSI add-on's identity `clientId` via `az aks show --query addonProfiles.azureKeyvaultSecretsProvider.identity.clientId` and set it explicitly as `userAssignedIdentityID` in the `SecretProviderClass`.

**Lesson**: a cluster can carry multiple managed identities for different add-ons simultaneously — "the managed identity" is not always singular, and authentication config needs to be explicit about which one applies.

---

## 8. Trivy Security Gate Blocking the Pipeline

**Symptom**: `container_scan` failed after enabling `trivy image --exit-code 1 --severity HIGH,CRITICAL`, reporting HIGH vulnerabilities in the Alpine base image (`libexpat`, `p11-kit`, `p11-kit-trust`) while the application JAR itself was clean.

**Diagnosis**: a local scan confirmed the vulnerabilities were entirely in outdated Alpine OS packages in the `eclipse-temurin:21-jre-alpine` runtime layer, not in Java dependencies — fixed versions existed upstream (e.g. `libexpat 2.8.1-r0 -> 2.8.2-r0`).

**Fix**: added `RUN apk update && apk upgrade` to the runtime stage of the Dockerfile, then rebuilt with `--no-cache` to guarantee the updated packages were actually installed (not served from a stale layer cache).

**Validation**: a rescan showed 0 vulnerabilities in both the OS layer and the application JAR.

**Security posture note**: the gate was deliberately never weakened with `--exit-code 0` — the image was fixed and rescanned until it passed, not exempted from the check.

**Lesson**: container scanning must cover OS packages, not just application dependencies — a clean application layer doesn't guarantee a secure image, and vulnerabilities should be fixed rather than bypassed by relaxing the scanner.

---

## 9. CLI Binary Accidentally Committed, Exceeding GitLab File Size Limit

**Symptom**: `git push` rejected — a 238 MiB blob (`argocd-linux-amd64`) exceeded the 100 MiB limit, already present in local commit history (not just staged).

**Diagnosis**: the ArgoCD CLI binary had been downloaded directly inside the project directory and picked up by a broad `git add`. Because it was already committed, `.gitignore` alone wouldn't remove it.

**Fix**: added it to `.gitignore`; purged it from history with `git filter-repo --path "argocd-linux-amd64" --invert-paths --force` (re-adding the remote afterward, since `filter-repo` strips it as a safety measure); moved the binary to `/usr/local/bin` to prevent recurrence.

**Lesson**: CLI tools should never live inside a project's working directory. A blob already committed requires history rewriting (`git filter-repo`/`git filter-branch`) — `.gitignore` and `git rm --cached` alone are not enough once it's in history.

---

## 10. CreateContainerConfigError — Non-Numeric User with `runAsNonRoot`

**Symptom**: after the ArgoCD sync, the pod failed to start: `Error: container has runAsNonRoot and image has non-numeric user (spring), cannot verify user is non-root`. As a side effect, the HPA also reported `<unknown>` CPU/memory metrics.

**Diagnosis**: the pod's `securityContext` required `runAsNonRoot: true` (enforced for defense-in-depth, matching the Kyverno `disallow-root-user` policy), but the Dockerfile created the container user by **name** only (`adduser -S spring`) rather than a fixed numeric UID/GID. Kubernetes can only verify `runAsNonRoot` against a numeric UID — it cannot resolve a named user inside the image to confirm it isn't UID 0. The HPA's `<unknown>` metrics were a downstream consequence: no container was ever running, so there was nothing for `metrics-server` to report on.

**Fix**: updated the Dockerfile to create the user with an explicit numeric UID/GID (`addgroup -g 1001 -S spring && adduser -u 1001 -S spring -G spring`, `USER 1001`), and declared the matching `runAsUser: 1001` in the Deployment's `securityContext`.

**Lesson**: `runAsNonRoot` policies (including Kyverno's `disallow-root-user` here) require numeric UIDs end-to-end — a named non-root user in the image is not sufficient on its own.

---

## 11. Kustomize Load Restriction — Cannot Reference Files Outside Overlay Root

**Symptom**: `kubectl kustomize k8s/overlays/dev` failed: `accumulating resources ... file '.../k8s/security/network-policies/default-deny-all.yaml' is not in or below '.../k8s/overlays/dev': must build at directory`.

**Diagnosis**: recent Kustomize versions restrict plain resource *files* referenced from a kustomization to its own directory tree, as a directory-traversal safety measure. The Network Policies were referenced as three individual files from outside that tree.

**Fix**: turned `k8s/security/network-policies/` into its own Kustomize base (its own `kustomization.yaml` listing the three files) — a directory with its own `kustomization.yaml` is exempt from this restriction, unlike individual files.

**Lesson**: Kustomize treats "plain resource files" and "base directories" under different rules — shared resources reused across overlays should always be packaged as a base.

---

## 12. GitLab CI Bot Token Rejected on Protected Branch

**Symptom**: the CI job that commits the updated image tag back to the repo failed: `You are not allowed to push code to protected branches on this project. (pre-receive hook declined)` — despite the Project Access Token having `write_repository` scope.

**Diagnosis**: GitLab enforces branch protection as a second, independent authorization layer on top of token scopes. Having the right scope does not bypass a protected branch's role restrictions.

**Fix**: updated the `master` protected branch rule to allow **Developers** to push directly, matching the token's role — rather than elevating the token itself to Maintainer.

**Lesson**: branch protection and token scopes are two separate GitLab authorization mechanisms; both must be satisfied. Prefer adjusting the protected branch's allowed roles over granting automation a higher role than it needs.

---

## 13. Prometheus Showing "No Data" — Missing ServiceMonitor

**Symptom**: Prometheus had no data at all for the application; even a manually built Grafana panel showed nothing, with no error anywhere.

**Diagnosis**: `kube-prometheus-stack` only scrapes targets it's explicitly told about — node-exporter and kube-state-metrics come pre-configured, custom applications don't. No `ServiceMonitor` existed for the app, so Prometheus never attempted to scrape it.

**Fix**: named the Service port explicitly (`ServiceMonitor` endpoints select by port **name**, not number), then created a `ServiceMonitor` matching the Service's labels — critically including the `release: monitoring` label required by the `Prometheus` custom resource's `serviceMonitorSelector`. Without that exact label match, a ServiceMonitor is silently ignored.

**Lesson**: check the `serviceMonitorSelector` on the `Prometheus` CR (`kubectl get prometheus -n monitoring -o yaml`) before assuming an applied ServiceMonitor manifest is actually active — "applied" and "picked up" are not the same thing.

---

## 14. 404 Scraping `/actuator/prometheus`

**Symptom**: once the ServiceMonitor was in place, Prometheus reported `Error scraping target: server returned HTTP status 404`.

**Diagnosis, step by step**:
1. Confirmed Service/label selectors were correct — Prometheus could reach the pod, ruling out a networking issue.
2. Port-forwarded directly to the pod: `curl localhost:8080/actuator` returned `200`, but `_links` only listed `health` — isolating the problem to the application layer, not Kubernetes.
3. Verified `management.endpoints.web.exposure.include=health,info,prometheus,metrics` and the `micrometer-registry-prometheus` Maven dependency were both present and correct in source.
4. Verified the built JAR actually contained the updated `application.properties` (`unzip -p target/*.jar BOOT-INF/classes/application.properties`) — confirmed correct.
5. **Root cause**: `kubectl get pod -o jsonpath='{.spec.containers[0].image}'` showed the running pod was on an image tag from an **older commit**, predating the Actuator config change — confirmed with `git show <old-tag>:src/main/resources/application.properties`.
6. A newer, correct pod was already scheduled but stuck `Pending` (see next issue).

**Fix**: once the new pod reached `Running`, `/actuator/prometheus` returned `200` with correctly formatted metrics.

**Lesson**: a 404 from an observability stack is rarely about the observability stack. Isolate app-level (`curl` directly to the pod) from cluster-level (Service/ServiceMonitor) first — and always confirm *which image* is actually running before debugging application code that might already be fixed in Git.

---

## 15. New Pod Stuck in Pending — Insufficient CPU

**Symptom**: the corrected pod (issue #14) sat `Pending` for 40+ minutes while the older pod kept running.

**Diagnosis**: `kubectl describe pod` showed `0/1 nodes are available: Insufficient cpu`. `kubectl top nodes` confirmed the node pool was near its CPU allocation limit — largely because the observability stack (Prometheus, Grafana, Alertmanager) was competing for capacity on the same node pool as the application at the time.

**Fix, in order of cost**:
1. Reviewed whether the Deployment's CPU requests were oversized relative to actual needs.
2. Manually deleted the stale old pod to immediately free capacity the rolling update wasn't reclaiming fast enough.
3. As a structural fix, added a **dedicated node pool for the observability stack** (`terraform/monitoring-node-pool.tf`, with a taint), so application and monitoring workloads no longer compete for the same node capacity.

**Lesson**: on a resource-constrained cluster, a `Pending` pod is very often a capacity problem caused by *co-located* workloads rather than the workload itself being misconfigured — isolating observability onto its own node pool resolved the recurring contention rather than just patching the symptom each time.

---

## 16. DNS Breakage After Applying `default-deny-all` NetworkPolicy

**Symptom**: after applying the default-deny Network Policy, the application pod could no longer resolve any hostname, including internal Kubernetes service names.

**Diagnosis**: `default-deny-all` blocks all egress by default, including DNS queries to CoreDNS on port 53 — Kubernetes does not implicitly allowlist DNS just because it's infrastructure traffic.

**Fix**: added `allow-dns.yaml`, explicitly permitting egress to `kube-system` on UDP/TCP port 53, applied alongside `default-deny-all`.

**Lesson**: when adopting a default-deny network model, DNS is the first thing that breaks and the easiest thing to forget — apply and test `allow-dns` in the same change as `default-deny-all`, not as an afterthought.

---

## 17. ArgoCD Application Controller OOMKilled — Stale Sync Status

**Symptom**: `portfolio-app-dev` stayed `OutOfSync`/degraded in the ArgoCD UI even though the actual Deployment was healthy. `kubectl get pods -n argocd` showed `argocd-application-controller-0` in a repeated `OOMKilled` crash loop.

**Diagnosis**: all cluster-critical components (ArgoCD's 7 pods, Kyverno's 4 controllers, CoreDNS, metrics-server, CSI drivers, etc.) were co-located on a single small node. `argocd-application-controller` keeps an in-memory cache of every manifest it watches, and its default memory limit was too low for that load on an already-pressured node — it kept getting OOM-killed before it could finish computing sync/health status, leaving the UI showing a stale result.

**Fix**: raised the controller's memory limit (`kubectl patch statefulset argocd-application-controller -n argocd ...`), then forced a hard refresh (`argocd.argoproj.io/refresh: hard` annotation) once it stabilized.

**Lesson**: a `Degraded`/`OutOfSync` status in ArgoCD doesn't always mean the *application* is unhealthy — it can mean ArgoCD itself couldn't finish evaluating it. Check ArgoCD's own component health (`kubectl get pods -n argocd`) before assuming the deployed workload is at fault.

---

## Summary of key debugging habits reinforced by this project

- Check CRD **label selectors** explicitly (`serviceMonitorSelector`, `ruleSelector`) rather than assuming an applied manifest is automatically "active."
- When something returns an unexpected HTTP status from inside the cluster, isolate app-level from cluster-level first with a direct `curl`, before touching Kubernetes config.
- Always confirm **which image tag** is actually deployed before assuming a code fix hasn't worked — `kubectl get pod -o jsonpath` + `git show <tag>:<file>` is a fast way to rule this in or out.
- Resource contention (`Pending` pods, OOM-killed control-plane components) on a small cluster is often caused by *neighboring* workloads — check `kubectl top nodes` before assuming the workload itself is misconfigured.
- A default-deny network policy needs DNS allowlisted explicitly, every time.
- A tool's own status UI (ArgoCD's sync/health) can itself be the thing that's broken — verify the tool's components are healthy before trusting what it reports about something else.

---

## 18. Grafana p95 Latency Panel Showing "No Data"

**Symptom**: three of the four panels in the custom Grafana dashboard displayed real data (HTTP request rate, CPU usage, HPA replica count), but "Latence p95" consistently showed "No data".

**Diagnosis**: the panel queries `histogram_quantile(0.95, rate(http_server_requests_seconds_bucket[5m]))`, which requires Micrometer to export **histogram buckets** for HTTP request duration. By default, Micrometer only exposes the counter and sum (`http_server_requests_seconds_count` / `_sum`) — the `_bucket` series needed for percentile calculation is not emitted unless explicitly enabled. Since `/actuator/prometheus` was otherwise working correctly (confirmed by the other three panels), the issue was isolated to this specific metric configuration, not scraping or connectivity.

**Fix**: added `management.metrics.distribution.percentiles-histogram.http.server.requests=true` to `application.properties`, then rebuilt/redeployed through the normal CI/CD pipeline.

**Lesson**: a metric endpoint returning `200` with valid Prometheus-formatted output doesn't guarantee every metric a dashboard expects is actually being exported — histogram-based queries (percentiles, quantiles) need buckets explicitly enabled per-metric in Micrometer, they aren't on by default even when the base metric exists.
