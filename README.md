# AKS infrastructure

Public repository: [pelithne/hsb-azure-day](https://github.com/pelithne/hsb-azure-day).

[infra/main.bicep](./infra/main.bicep) deploys the following into an existing Azure resource group:

| Component | Configuration |
| --- | --- |
| Region | Sweden Central (`swedencentral`) |
| AKS | Free control-plane tier, managed identity, Kubernetes RBAC |
| System node pool | 2 Linux nodes, `Standard_D4s_v5` (4 vCPUs, 16 GiB RAM each) |
| User node pool | 1 Linux node, `Standard_D4s_v5` |
| Networking | Azure CNI Overlay with the Cilium dataplane |
| API server | Public; optionally restricted to configured CIDR ranges |
| Azure Container Registry | Basic tier, admin account disabled |
| Registry integration | `AcrPull` assigned to the AKS kubelet identity at registry scope |
| GitOps | Azure Flux v2 extension, stable release train, automatic minor-version upgrades |
| Workload identity | OIDC issuer and Microsoft Entra Workload ID enabled |

Node counts are fixed; autoscaling is disabled. Upgrades may temporarily add one surge node per pool. The Kubernetes version is not pinned, so Azure selects its supported default at initial deployment. AKS creates its own node resource group and virtual network.

Flux is installed **without a Git repository configuration**. It will not synchronize applications until you configure a source, as shown below. Workload identity is available, but no per-application identities, federated credentials, or Azure resource permissions are created automatically.

## Deploy

Requirements:

- Azure CLI with Bicep support (`az bicep version`).
- An Azure subscription with sufficient quota and availability for three `Standard_D4s_v5` nodes in Sweden Central (12 steady-state vCPUs, plus upgrade surge capacity).
- Permission to create resources **and role assignments**, for example Contributor plus Role Based Access Control Administrator scoped to the resource group, or Owner.

Sign in, select the subscription, and register the resource providers if necessary:

```bash
az login
az account set --subscription '<subscription-id>'

az provider register --namespace Microsoft.ContainerService --wait
az provider register --namespace Microsoft.ContainerRegistry --wait
az provider register --namespace Microsoft.KubernetesConfiguration --wait
az provider register --namespace Microsoft.Kubernetes --wait

az group create --name rg-hsb-azure-day --location swedencentral
```

Review or customize [infra/main.bicepparam](./infra/main.bicepparam), then preview and deploy:

```bash
az deployment group what-if \
  --resource-group rg-hsb-azure-day \
  --parameters infra/main.bicepparam

az deployment group create \
  --name aks-infrastructure \
  --resource-group rg-hsb-azure-day \
  --parameters infra/main.bicepparam
```

The parameter file references the template, so a separate `--template-file` is not required. The registry name defaults to `acr` plus a deterministic suffix based on the resource group ID. Override `acrName` if needed.

The public API accepts connections from any IP by default; Kubernetes authentication and authorization still apply. To restrict access, add a parameter to the parameter file before deployment:

```bicep
param apiServerAuthorizedIpRanges = [
  '203.0.113.10/32'
]
```

Replace the example with your real public egress IP/CIDR, including any automation that needs API access.

## Verify the cluster and registry integration

```bash
az aks get-credentials \
  --resource-group rg-hsb-azure-day \
  --name aks-hsb-azure-day

kubectl get nodes -L kubernetes.azure.com/mode,kubernetes.azure.com/agentpool

az aks show --resource-group rg-hsb-azure-day --name aks-hsb-azure-day \
  --query '{dataplane:networkProfile.networkDataplane,networkMode:networkProfile.networkPluginMode,privateAPI:apiServerAccessProfile.enablePrivateCluster,oidc:oidcIssuerProfile.enabled,workloadIdentity:securityProfile.workloadIdentity.enabled,pools:agentPoolProfiles[].{name:name,mode:mode,count:count,vmSize:vmSize}}'

ACR_NAME=$(az deployment group show \
  --resource-group rg-hsb-azure-day --name aks-infrastructure \
  --query properties.outputs.acrName.value --output tsv)

az aks check-acr \
  --resource-group rg-hsb-azure-day \
  --name aks-hsb-azure-day \
  --acr "${ACR_NAME}.azurecr.io"
```

Allow for Azure role-assignment propagation before testing image pulls. Applications can pull images from the registry without an `imagePullSecret`; pushing images requires separate permissions for the developer or CI identity.

`System` mode does not prevent application pods from running on system nodes. To target the user pool, add `nodeSelector: { kubernetes.azure.com/agentpool: user }` to the pod spec.

## Connect a GitOps repository later

Install the CLI extensions and check the Flux installation:

```bash
az extension add --name k8s-extension
az extension add --name k8s-configuration

az k8s-extension show \
  --resource-group rg-hsb-azure-day \
  --cluster-name aks-hsb-azure-day \
  --cluster-type managedClusters \
  --name flux

kubectl get pods --namespace flux-system
```

Configure synchronization from your repository:

```bash
az k8s-configuration flux create \
  --resource-group rg-hsb-azure-day \
  --cluster-name aks-hsb-azure-day \
  --cluster-type managedClusters \
  --name cluster-config \
  --namespace flux-system \
  --scope cluster \
  --url 'https://github.com/<organization>/<gitops-repository>' \
  --branch main \
  --kustomization name=apps path=./clusters/hsb-azure-day prune=true
```

Replace the URL, branch, and path with an existing source containing your Kubernetes manifests/Kustomize configuration. This example assumes a public repository. For a private repository, configure Flux repository authentication through Azure's supported secret options; do not commit tokens or private keys. `prune=true` removes previously managed Kubernetes resources when they are removed from Git.

## Use workload identity for an application

For each application, create a user-assigned managed identity, grant it only the Azure resource permissions it needs, and add a federated credential matching its Kubernetes namespace and service account:

```bash
az identity create --resource-group rg-hsb-azure-day --name id-example-app

OIDC_ISSUER=$(az aks show \
  --resource-group rg-hsb-azure-day --name aks-hsb-azure-day \
  --query oidcIssuerProfile.issuerUrl --output tsv)

az identity federated-credential create \
  --resource-group rg-hsb-azure-day \
  --identity-name id-example-app \
  --name example-app \
  --issuer "$OIDC_ISSUER" \
  --subject system:serviceaccount:apps:example-app \
  --audiences api://AzureADTokenExchange

az identity show --resource-group rg-hsb-azure-day --name id-example-app \
  --query '{clientId:clientId,principalId:principalId}'
```

Use that identity's `principalId` for Azure role assignments and its `clientId` in the service account annotation. Include these settings in your application manifests, replacing `<managed-identity-client-id>`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: apps
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: example-app
  namespace: apps
  annotations:
    azure.workload.identity/client-id: "<managed-identity-client-id>"
```

On the Deployment's pod template, set:

```yaml
spec:
  template:
    metadata:
      labels:
        azure.workload.identity/use: "true"
    spec:
      serviceAccountName: example-app
```

The application must use a workload-identity-capable Azure SDK credential (for example, `DefaultAzureCredential`) to exchange the projected service-account token. Enabling the cluster feature alone does not grant pods access to Azure resources.

## GitHub Actions CI/CD

[.github/workflows/infrastructure.yml](./.github/workflows/infrastructure.yml) runs:

- **CI** on pull requests targeting `main`, pushes to `main`, and manual workflow runs. It compiles/lints the Bicep templates and parameter file and runs [infrastructure tests](./tests/test_infrastructure.py). No Azure credentials are used in CI.
- **CD** after successful CI for pushes to `main` or manual runs on `main`. The deployment job uses the protected `production` environment and waits for a reviewer approval. It signs in through OIDC, runs an Azure `what-if`, and deploys in incremental mode. The preview runs **after** environment approval; inspect it in the job logs.

Deployments are serialized and running deployments are not cancelled by subsequent commits. Actions are pinned to commit SHAs, and the Bicep version is pinned. Fork pull requests cannot run the deployment job.

### One-time Azure and GitHub configuration

The deployment target is subscription **Student11**, resource group `rg-hsb-azure-day` in Sweden Central. The pipeline does not create the resource group or register providers; bootstrap them once using an administrative Azure account:

```bash
az account set --subscription Student11
az group create --name rg-hsb-azure-day --location swedencentral

az provider register --namespace Microsoft.ContainerService --wait
az provider register --namespace Microsoft.ContainerRegistry --wait
az provider register --namespace Microsoft.KubernetesConfiguration --wait
az provider register --namespace Microsoft.Kubernetes --wait
az provider register --namespace Microsoft.ManagedIdentity --wait

az deployment group create \
  --name github-oidc-bootstrap \
  --resource-group rg-hsb-azure-day \
  --template-file infra/github-oidc.bicep
```

[infra/github-oidc.bicep](./infra/github-oidc.bicep) creates a user-assigned identity with:

- A federated credential issued by `https://token.actions.githubusercontent.com`, with audience `api://AzureADTokenExchange` and subject `repo:pelithne@45140408/hsb-azure-day@1408351006:environment:production`.
- **Contributor** and **Role Based Access Control Administrator** at the resource-group scope, not subscription scope. Role administration is required because the AKS template assigns ACR pull access. This is a privileged identity: protect environment approval and restrict deployment branches.

No Azure client secret is needed. This identity is for GitHub deployments and is separate from identities used by application pods.

This repository uses GitHub's immutable OIDC subjects, which include the owner and repository IDs. Azure must trust the **exact** subject emitted by GitHub, not the legacy name-only subject. Inspect the repository configuration with:

```bash
gh api repos/pelithne/hsb-azure-day/actions/oidc/customization/sub \
  --jq '{use_immutable_subject, sub_claim_prefix}'
```

The bootstrap's `githubSubjectPrefix` parameter matches `sub_claim_prefix`; the template appends `:environment:production`. When reusing the template for another repository, use its actual prefix. A login failure with `AADSTS700213` indicates that the emitted subject, issuer, or audience does not match an Azure federated credential; compare the login step's claim details with the credential and reapply the corrected bootstrap.

In GitHub **Settings > Environments > production**, configure:

1. Required reviewer: `pelithne`. Self-review is allowed so the repository owner can approve their own changes.
2. Deployment branches: selected branches, allowing only `main`.
3. Disable administrator bypass of environment protection.
4. The following environment **variables**, using the bootstrap deployment outputs:

| Variable | Bootstrap output |
| --- | --- |
| `AZURE_CLIENT_ID` | `clientId` |
| `AZURE_TENANT_ID` | `tenantId` |
| `AZURE_SUBSCRIPTION_ID` | `subscriptionId` |
| `AZURE_RESOURCE_GROUP` | `resourceGroupName` |

Read the values without storing them in source control:

```bash
az deployment group show \
  --resource-group rg-hsb-azure-day \
  --name github-oidc-bootstrap \
  --query properties.outputs \
  --output json
```

The bootstrap is separate from the normal deployment workflow to avoid giving the pipeline responsibility for changing its own trust configuration. Allow time for Azure role assignments and federated credentials to propagate before approving the first deployment.

To deploy, merge an infrastructure change into `main`, then approve the waiting deployment in the repository's **Actions** tab. To retry without a new commit, use **Run workflow** on `main`. Review Azure quota and expected cost before approval; CI does not provision or validate live cluster capacity.

## Local template validation

```bash
mkdir -p build
az bicep build --file infra/main.bicep --outfile build/main.json
az bicep build-params --file infra/main.bicepparam --outfile build/main.parameters.json
az bicep build --file infra/github-oidc.bicep --outfile build/github-oidc.json
python3 -m unittest discover --start-directory tests --verbose
```

Compilation checks syntax and resource schemas. An Azure `what-if`/deployment is still needed to validate subscription permissions, regional SKU availability, quota, and runtime provisioning.
