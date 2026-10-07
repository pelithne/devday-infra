# AKS infrastructure

Public repository: [pelithne/devday-infra](https://github.com/pelithne/devday-infra).

[infra/main.bicep](./infra/main.bicep) deploys the following into an existing Azure resource group:

| Component | Configuration |
| --- | --- |
| AKS region | North Europe (`northeurope`) |
| ACR region | Sweden Central (`swedencentral`) |
| AKS | Free control-plane tier, managed identity, Kubernetes RBAC |
| System node pool | 2 Linux nodes, `Standard_D4s_v6` (4 vCPUs, 16 GiB RAM each) |
| User node pool | 1 Linux node, `Standard_D4s_v6` |
| Networking | Azure CNI Overlay with the Cilium dataplane |
| API server | Public; optionally restricted to configured CIDR ranges |
| Azure Container Registry | Basic tier, admin account disabled |
| Registry integration | `AcrPull` assigned to the AKS kubelet identity at registry scope |
| GitOps | Azure Flux v2 extension and synchronization of `devday-demoapp` manifests |
| Workload identity | OIDC issuer and Microsoft Entra Workload ID enabled |

Node counts are fixed; autoscaling is disabled. Upgrades may temporarily add one surge node per pool. The Kubernetes version is not pinned, so Azure selects its supported default at initial deployment. AKS creates its own node resource group and virtual network.

AKS is deployed in North Europe because Sweden Central rejected cluster creation with `AKSCapacityHeavyUsage`. ACR is deployed in Sweden Central with pull access granted to the cluster. Cross-region image pulls may add latency and inter-region data-transfer charges. The resource group and GitHub deployment identity are also located in Sweden Central; their locations do not constrain the cluster's region.

The node SKU uses `Standard_D4s_v6` because this subscription does not allow `Standard_D4s_v5` in North Europe. Both sizes provide 4 vCPUs and 16 GiB RAM.

Flux synchronizes [pelithne/devday-demoapp](https://github.com/pelithne/devday-demoapp), branch `main`, path `./deploy`, every minute. The demo voting app runs a public Nginx frontend and a separate Flask API with SQLite on an Azure Disk PVC. App CI publishes images to ACR and commits their versions to Git; Flux deploys them without CI accessing AKS. Workload identity is available, but no pod-specific identities or permissions are created automatically.

## Deploy

Requirements:

- Azure CLI with Bicep support (`az bicep version`).
- An Azure subscription with sufficient quota and availability for three `Standard_D4s_v6` nodes in North Europe (12 steady-state vCPUs, plus upgrade surge capacity).
- Permission to create resources **and role assignments**, for example Contributor plus Role Based Access Control Administrator scoped to the resource group, or Owner.

Sign in, select the subscription, and register the resource providers if necessary:

```bash
az login
az account set --subscription '<subscription-id>'

az provider register --namespace Microsoft.ContainerService --wait
az provider register --namespace Microsoft.ContainerRegistry --wait
az provider register --namespace Microsoft.KubernetesConfiguration --wait
az provider register --namespace Microsoft.Kubernetes --wait

az group create --name rg-azure-day --location swedencentral
```

Review or customize [infra/main.bicepparam](./infra/main.bicepparam), then preview and deploy:

```bash
az deployment group what-if \
  --resource-group rg-azure-day \
  --parameters infra/main.bicepparam

az deployment group create \
  --name aks-infrastructure \
  --resource-group rg-azure-day \
  --parameters infra/main.bicepparam
```

The parameter file references the template, so a separate `--template-file` is not required. The registry name defaults to `acr` plus a deterministic suffix based on the resource group ID. Override `acrName` if needed.

A deployment to a differently named resource group creates a new registry name; existing images and Kubernetes data are not migrated. Back up anything needed before deleting the previous resource group. Azure resource groups are not renamed in place: bootstrap the new group and its deployment identity, update the GitHub environment variables, then approve the new infrastructure deployment.

`location` controls the AKS region, while `acrLocation` independently controls the registry region. Keep `acrLocation` and `acrName` unchanged when reusing an existing registry; changing its region in place is not supported.

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
  --resource-group rg-azure-day \
  --name aks-azure-day

kubectl get nodes -L kubernetes.azure.com/mode,kubernetes.azure.com/agentpool

az aks show --resource-group rg-azure-day --name aks-azure-day \
  --query '{location:location,dataplane:networkProfile.networkDataplane,networkMode:networkProfile.networkPluginMode,privateAPI:apiServerAccessProfile.enablePrivateCluster,oidc:oidcIssuerProfile.enabled,workloadIdentity:securityProfile.workloadIdentity.enabled,pools:agentPoolProfiles[].{name:name,mode:mode,count:count,vmSize:vmSize}}'

ACR_NAME=$(az deployment group show \
  --resource-group rg-azure-day --name aks-infrastructure \
  --query properties.outputs.acrName.value --output tsv)

az aks check-acr \
  --resource-group rg-azure-day \
  --name aks-azure-day \
  --acr "${ACR_NAME}.azurecr.io"
```

Allow for Azure role-assignment propagation before testing image pulls. Applications can pull images from the registry without an `imagePullSecret`; pushing images requires separate permissions for the developer or CI identity.

`System` mode does not prevent application pods from running on system nodes. To target the user pool, add `nodeSelector: { kubernetes.azure.com/agentpool: user }` to the pod spec.

## Demo application GitOps

[infra/demoapp-gitops.bicep](./infra/demoapp-gitops.bicep) is included in the main deployment after Flux is installed. It can also configure an already-deployed cluster without redeploying AKS:

```bash
az deployment group create \
  --subscription Student11 \
  --resource-group rg-azure-day \
  --name demoapp-gitops \
  --template-file infra/demoapp-gitops.bicep
```

The source reconciles `main` in [devday-demoapp](https://github.com/pelithne/devday-demoapp) with pruning and health checks enabled. The app namespace and data PVC are explicitly non-prunable to protect votes; explicit deletion still destroys data. See the application's README for its delivery pipeline, voting model, demo script, and teardown guidance.

Find the app's public HTTP address and check reconciliation:

```bash
kubectl get service frontend -n devday-demoapp
kubectl get gitrepositories,kustomizations -n flux-system
kubectl get pods,pvc -n devday-demoapp
```

## Connect an additional GitOps repository

Install the CLI extensions and check the Flux installation:

```bash
az extension add --name k8s-extension
az extension add --name k8s-configuration

az k8s-extension show \
  --resource-group rg-azure-day \
  --cluster-name aks-azure-day \
  --cluster-type managedClusters \
  --name flux

kubectl get pods --namespace flux-system
```

Configure synchronization from your repository:

```bash
az k8s-configuration flux create \
  --resource-group rg-azure-day \
  --cluster-name aks-azure-day \
  --cluster-type managedClusters \
  --name cluster-config \
  --namespace flux-system \
  --scope cluster \
  --url 'https://github.com/<organization>/<gitops-repository>' \
  --branch main \
  --kustomization name=apps path=./clusters/azure-day prune=true
```

Replace the URL, branch, and path with an existing source containing your Kubernetes manifests/Kustomize configuration. This example assumes a public repository. For a private repository, configure Flux repository authentication through Azure's supported secret options; do not commit tokens or private keys. `prune=true` removes previously managed Kubernetes resources when they are removed from Git.

## Use workload identity for an application

For each application, create a user-assigned managed identity, grant it only the Azure resource permissions it needs, and add a federated credential matching its Kubernetes namespace and service account:

```bash
az identity create --resource-group rg-azure-day --name id-example-app

OIDC_ISSUER=$(az aks show \
  --resource-group rg-azure-day --name aks-azure-day \
  --query oidcIssuerProfile.issuerUrl --output tsv)

az identity federated-credential create \
  --resource-group rg-azure-day \
  --identity-name id-example-app \
  --name example-app \
  --issuer "$OIDC_ISSUER" \
  --subject system:serviceaccount:apps:example-app \
  --audiences api://AzureADTokenExchange

az identity show --resource-group rg-azure-day --name id-example-app \
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

The deployment target is subscription **Student11**, resource group `rg-azure-day`, cluster `aks-azure-day`, and deployment identity `id-azure-day-github-actions`. The resource group and deployment identity are in Sweden Central, while the AKS cluster is created in North Europe. The pipeline does not create the resource group or register providers; bootstrap them once using an administrative Azure account:

```bash
az account set --subscription Student11
az group create --name rg-azure-day --location swedencentral

az provider register --namespace Microsoft.ContainerService --wait
az provider register --namespace Microsoft.ContainerRegistry --wait
az provider register --namespace Microsoft.KubernetesConfiguration --wait
az provider register --namespace Microsoft.Kubernetes --wait
az provider register --namespace Microsoft.ManagedIdentity --wait

az deployment group create \
  --name github-oidc-bootstrap \
  --resource-group rg-azure-day \
  --template-file infra/github-oidc.bicep
```

[infra/github-oidc.bicep](./infra/github-oidc.bicep) creates a user-assigned identity with:

- A federated credential issued by `https://token.actions.githubusercontent.com`, with audience `api://AzureADTokenExchange` and subject `repo:pelithne@45140408/devday-infra@1408351006:environment:production`.
- **Contributor** and **Role Based Access Control Administrator** at the resource-group scope, not subscription scope. Role administration is required because the AKS template assigns ACR pull access. This is a privileged identity: protect environment approval and restrict deployment branches.

No Azure client secret is needed. This identity is for GitHub deployments and is separate from identities used by application pods.

This repository uses GitHub's immutable OIDC subjects, which include the owner and repository IDs. Azure must trust the **exact** subject emitted by GitHub, not the legacy name-only subject. Inspect the repository configuration with:

```bash
gh api repos/pelithne/devday-infra/actions/oidc/customization/sub \
  --jq '{use_immutable_subject, sub_claim_prefix}'
```

The bootstrap's `githubSubjectPrefix` parameter matches `sub_claim_prefix`; the template appends `:environment:production`. When reusing the template for another repository, use its actual prefix. A login failure with `AADSTS700213` indicates that the emitted subject, issuer, or audience does not match an Azure federated credential; compare the login step's claim details with the credential and reapply the corrected bootstrap.

After renaming the repository, recheck `sub_claim_prefix` and update the bootstrap and Azure credential before running CD. The subject includes the repository name even when immutable IDs are enabled. Repository renames do not require changing the Azure resource names.

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
  --resource-group rg-azure-day \
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
