# Terraform & Azure Troubleshooting

## 1. Azure Region Restriction

### Symptom
Terraform failed when creating the Virtual Network with:
```
RequestDisallowedByAzure:
The selected region is currently not accepting new customers.
```

### Diagnosis
The Azure subscription was authenticated correctly, but the selected
region (`westeurope`) was not accepting new customers for this subscription.

### Resolution
The deployment region was changed to `francecentral`.

### Validation
The Resource Group and Virtual Network were successfully created.

---

## 2. Subnet Resource Not Found During Terraform Polling

### Symptom
Terraform reported:
```
ResourceNotFound:
The Resource 'Microsoft.Network/virtualNetworks/...' was not found.
```
The error occurred while Terraform was waiting for the subnet
provisioning state.

### Diagnosis
Azure CLI confirmed that the Virtual Network existed:
```
ProvisioningState: Succeeded
```
The subnet also existed:
```
ProvisioningState: Succeeded
```
However, `terraform state list` showed only:
```
azurerm_resource_group.main
azurerm_virtual_network.main
```
The subnet was therefore missing from the Terraform state.

### Resolution
The existing Azure subnet was imported into Terraform:
```
terraform import azurerm_subnet.aks <resource-id>
```

### Validation
```
terraform plan
```
The Terraform configuration, state and Azure infrastructure were
then reconciled.

---

## 3. Terraform Provider Exceeding GitLab File Size Limit

### Symptom
GitLab rejected the push because a blob exceeded the repository's
100 MiB file size limit:
```
GitLab: You are attempting to check in one or more blobs which exceed the 100.0MiB limit:
- 9f5f0b9feb7626a0f53112f1b3fe7c603101616d (223 MiB)
```

### Diagnosis
The large file was identified using:
```
git ls-tree -r HEAD | grep 9f5f0b9feb7626a0f53112f1b3fe7c603101616d
```
The file was:
```
terraform/.terraform/providers/registry.terraform.io/hashicorp/azurerm/3.117.1/linux_amd64/terraform-provider-azurerm_v3.117.1_x5
```
The 223 MiB file was the AzureRM Terraform provider binary
downloaded automatically by `terraform init`.
The `.terraform/` directory and Terraform state files should not be
versioned because they are generated locally.

### Resolution
The `.terraform/` directory and Terraform state files were added to
`.gitignore`:
```
# Terraform
.terraform/
*.tfstate
*.tfstate.*
*.tfvars
*.tfvars.json
crash.log
crash.*.log
```
The already tracked files were removed from Git tracking:
```
git rm -r --cached terraform/.terraform
git rm --cached terraform/terraform.tfstate
git rm --cached terraform/terraform.tfstate.backup
```
The latest commit was then amended to remove these files from the
Git history of the unpushed commit:
```
git commit --amend --no-edit
```
The `.terraform.lock.hcl` file was kept under version control because
it locks the Terraform provider version and checksums.

### Validation
The repository was checked to ensure that the Terraform provider
and state files were no longer tracked:
```
git ls-tree -r HEAD --name-only | grep 'terraform/.terraform/'
git ls-tree -r HEAD --name-only | grep 'terraform.tfstate'
```
No results were returned.
The repository was then successfully pushed to GitLab:
```
git push origin master
```
Git confirmed:
```
master -> master
Your branch is up to date with 'origin/master'.
nothing to commit, working tree clean
```

---

## 4. AKS VM Size Not Allowed for Subscription

### Symptom
`terraform apply` failed when creating the AKS cluster with:
```
BadRequest:
The VM size of Standard_B2s is not allowed in your subscription
in location 'francecentral'. The available VM sizes are
'standard_d2ads_v7, standard_d4ads_v7, ...'
```

### Diagnosis
The Azure free trial subscription restricts available VM SKUs per
region to a specific allow-list. `Standard_B2s` (B-series, low-cost
burstable) was not part of that list for `francecentral`, even
though it is a common and widely documented AKS node size.

### Resolution
The node pool `vm_size` was changed to `Standard_D2ads_v7`, the
smallest SKU present in the list of allowed sizes returned by Azure
for this subscription and region.

### Validation
```
terraform plan
terraform apply
```
The AKS cluster was created successfully with the new VM size.

---

## 5. kubectl Using K3s Instead of AKS

### Symptom
After retrieving the AKS cluster credentials with:
```
az aks get-credentials \
  --resource-group rg-hajar-azure-project-dev \
  --name aks-hajar-azure-project-dev
```
Azure CLI successfully reported:
```
Merged "aks-hajar-azure-project-dev" as current context in /home/hajar/.kube/config
```
However, running:
```
kubectl get nodes
```
failed with:
```
Unable to read /etc/rancher/k3s/k3s.yaml
error: error loading config file "/etc/rancher/k3s/k3s.yaml":
open /etc/rancher/k3s/k3s.yaml: permission denied
```

### Diagnosis
The WSL environment already had a K3s installation running. The
`kubectl` command was not the standard Kubernetes client — it was a
symbolic link to the K3s binary:
```
which kubectl
# /usr/local/bin/kubectl

ls -l /usr/local/bin/kubectl
# /usr/local/bin/kubectl -> k3s
```
K3s was confirmed to be running:
```
sudo systemctl status k3s
# Active: active (running)
```
Therefore `kubectl` was reading the K3s-specific configuration
(`/etc/rancher/k3s/k3s.yaml`) instead of the AKS kubeconfig generated
by Azure CLI (`/home/hajar/.kube/config`). The `KUBECONFIG`
environment variable was empty, so the issue was not caused by an
explicitly configured `KUBECONFIG`.

### Root Cause
The K3s installation had replaced the standard `kubectl` command with
a symbolic link to the K3s binary (`/usr/local/bin/kubectl -> k3s`),
creating a conflict between the existing local K3s environment and
the new Azure AKS environment.

### Resolution
The official Kubernetes `kubectl` client was downloaded for
linux/amd64:
```
curl -LO https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl
chmod +x ./kubectl
sudo mv ./kubectl /usr/local/bin/kubectl
```
Installation was verified with:
```
kubectl version --client
# Client Version: v1.36.3
# Kustomize Version: v5.8.1
```
The K3s cluster itself was not removed or disabled — only the
`kubectl` symbolic link was replaced with the official client.

### Validation
The AKS context was retrieved again:
```
az aks get-credentials \
  --resource-group rg-hajar-azure-project-dev \
  --name aks-hajar-azure-project-dev

kubectl config current-context
kubectl get nodes
```

### Lesson Learned
`kubectl` is only the CLI client that talks to a cluster's API
Server — it is not tied to any specific cluster. K3s ships its own
kubectl integration and kubeconfig, which can conflict with a
standard Kubernetes client when managing an external cluster such as
AKS. A standard `kubectl` client can manage both K3s and AKS; the
target cluster is determined solely by the active context in
`~/.kube/config`. The local K3s environment can therefore coexist
with the Azure AKS environment without requiring K3s to be
uninstalled.

---

## 6. AKS OIDC Issuer Feature Cannot Be Disabled

### Symptom
`terraform apply` failed while updating the AKS cluster (triggered by
adding the Key Vault CSI provider) with:
```
Error: updating Kubernetes Cluster: unexpected status 400 (400 Bad Request):
{
  "code": "OIDCIssuerFeatureCannotBeDisabled",
  "message": "OIDC issuer feature cannot be disabled."
}
```
The plan showed:
```
- oidc_issuer_enabled = true -> null
```

### Diagnosis
The `oidc_issuer_enabled` attribute was never explicitly set in
`aks.tf`. Azure enables the OIDC issuer by default on new AKS
clusters, but the Terraform configuration's implicit default (unset
= null/false) caused Terraform to attempt disabling a feature that
Azure does not allow to be turned off once active.

### Resolution
`oidc_issuer_enabled = true` was added explicitly to the
`azurerm_kubernetes_cluster` resource block, so Terraform's desired
state matches the actual state on Azure and no longer attempts to
disable it.

### Validation
```
terraform plan
```
No further changes were proposed for `oidc_issuer_enabled`.
```
terraform apply
```
The Key Vault, the demo secret, and the two role assignments (created
earlier in the same run before the error) were left untouched; only
the AKS cluster update succeeded on retry.

---

## 7. CSI Driver Failing to Authenticate — Multiple Managed Identities

### Symptom
The test pod stayed stuck in `ContainerCreating`. `kubectl describe pod`
showed:
```
Warning  FailedMount  ...  kubelet
MountVolume.SetUp failed for volume "secrets-store": ...
ManagedIdentityCredential: failed to authenticate a system assigned identity.
The endpoint responded with {"error":"invalid_request",
"error_description":"Multiple user assigned identities exist,
please specify the clientId / resourceId of the identity in the
token request"}
```

### Diagnosis
The AKS cluster has more than one managed identity attached: the
kubelet identity (used for ACR pulls) and the identity automatically
created by the `key_vault_secrets_provider` add-on (used for Key
Vault access). The `SecretProviderClass` was configured with
`useVMManagedIdentity: "true"` but without specifying which identity
to use, making the authentication request ambiguous.

### Resolution
The CSI driver identity's `clientId` was retrieved:
```
az aks show --resource-group rg-hajar-azure-project-dev \
  --name aks-hajar-azure-project-dev \
  --query addonProfiles.azureKeyvaultSecretsProvider.identity.clientId -o tsv
```
It was added explicitly to `SecretProviderClass` via
`userAssignedIdentityID`.

### Validation
```
kubectl apply -f secret-provider-class.yaml
kubectl delete pod test-secret-pod
kubectl apply -f test-secret-pod.yaml
kubectl exec test-secret-pod -- cat /mnt/secrets/demo-secret
```
The pod reached `Running` and returned the expected secret value.

---

## 8. Trivy Security Gate Blocking the Pipeline

### Symptom
The `container_scan` job failed after enabling:
```
trivy image --exit-code 1 --severity HIGH,CRITICAL --input image.tar
```

### Diagnosis
The Trivy scanner itself executed successfully and detected
vulnerabilities in both the Alpine base image and the Java
dependencies. The scan reported:
- 3 HIGH vulnerabilities in the Alpine base image
- 15 HIGH vulnerabilities in Java dependencies
- 3 CRITICAL vulnerabilities in Java dependencies

Because `--exit-code 1` was configured, Trivy returned exit code 1
when HIGH or CRITICAL vulnerabilities were detected.

### Resolution
The failure was intentional: the Trivy scan acts as a security gate
preventing vulnerable images from being pushed to ACR. The
application dependencies and base image must be updated to reduce
the detected vulnerabilities before allowing the pipeline to
continue.

### Validation
The pipeline should be rerun after updating the affected
dependencies and rebuilding the container image. The expected result
is that the `container_scan` job completes successfully with no
blocking HIGH/CRITICAL vulnerabilities.
