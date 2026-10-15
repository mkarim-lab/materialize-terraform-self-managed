# Example: Simple Materialize Deployment on Azure

This example demonstrates how to deploy a complete Materialize environment on Azure using the modular Terraform setup from this repository.

---

## What Gets Created

This example provisions the following infrastructure:

### Resource Group

- **Resource Group**: New resource group to contain all resources

### Networking

- **Virtual Network**: 20.0.0.0/16 address space
- **AKS Subnet**: 20.0.0.0/20 with NAT Gateway association and service endpoints for Storage and SQL
- **PostgreSQL Subnet**: 20.0.16.0/24 delegated to PostgreSQL Flexible Server
- **NAT Gateway**: Standard SKU with static public IP for outbound connectivity
- **Private DNS Zone**: For PostgreSQL private endpoint resolution with VNet link

### Compute

- **AKS Cluster**: Version 1.34 with Cilium networking (network plugin: azure, data plane: cilium, policy: cilium)
- **Default Node Pool**: Standard_D4pds_v6 VMs, autoscaling 2-5 nodes, labeled for generic workloads
- **Materialize Node Pool**: Standard_E4pds_v6 VMs with 100GB disk, autoscaling 2-5 nodes, swap enabled, dedicated taints for Materialize workloads
- **Managed Identities**:
  - AKS cluster identity: Used by AKS control plane to provision Azure resources (creating load balancers when Materialize LoadBalancer services are created, managing network interfaces)
  - Workload identity: Used by Materialize pods for secure, passwordless authentication to Azure Storage (no storage account keys stored in cluster)

### Database

- **Azure PostgreSQL Flexible Server**: Version 15
- **SKU**: GP_Standard_D2s_v3 (2 vCores, 4GB memory)
- **Storage**: 32GB with 7-day backup retention
- **Network Access**: Public Network Access is disabled, Private access only (no public endpoint)
- **Database**: `materialize` database pre-created

### Storage

- **Storage Account**: Premium BlockBlobStorage with LRS replication for Materialize persistence
- **Container**: `materialize` blob container
- **Access Control**: Workload Identity federation for Kubernetes service account (passwordless authentication via OIDC)
- **Network Access**: Currently allows all traffic (production deployments should restrict to AKS subnet only traffic)

### Kubernetes Add-ons

- **cert-manager**: Certificate management controller for Kubernetes that automates TLS certificate provisioning and renewal
- **Self-signed ClusterIssuer**: Provides self-signed TLS certificates for Materialize instance internal communication (balancerd, console). Used by the Materialize instance for secure inter-component communication.

### Materialize

- **Operator**: Materialize Kubernetes operator
- **Instance**: Single Materialize instance in `materialize-environment` namespace
- **Load Balancers**: Internal Azure Load Balancers for Materialize access

---

## Required Features

Your Azure subscription needs certain features enabled.

```bash
# Enable the API Server VNet Integration preview feature:
# This allows the AKS API server to be placed inside your VNet for enhanced security
az feature register \
  --namespace Microsoft.ContainerService \
  --name EnableAPIServerVnetIntegrationPreview

# Check the status of the required feature:
az feature show \
  --namespace Microsoft.ContainerService \
  --name EnableAPIServerVnetIntegrationPreview
```

- Reference: https://learn.microsoft.com/en-us/azure/aks/api-server-vnet-integration#prerequisites

---

## Getting Started

### Step 1: Set Required Variables

Before running Terraform, create a `terraform.tfvars` file with the following variables:

```hcl
subscription_id     = "12345678-1234-1234-1234-123456789012"
resource_group_name = "materialize-demo-rg"
name_prefix         = "simple-demo"
location            = "westus2"
license_key         = "your-materialize-license-key"  # Optional: Get from https://materialize.com/self-managed/
tags = {
  environment = "demo"
}
```

**Required Variables:**

- `subscription_id`: Azure subscription ID
- `resource_group_name`: Name for the resource group (will be created)
- `name_prefix`: Prefix for all resource names
- `location`: Azure region for deployment
- `tags`: Map of tags to apply to resources
- `license_key`: Materialize license key


### Configuring Load Balancer Ingress CIDR Blocks

To restrict Load Balancer access to specific IP ranges:

```hcl
ingress_cidr_blocks = ["203.0.113.0/24", "198.51.100.0/24"]
```

---
### Check the bash path is correct 
```bash 
Get-Command bash -All | Select-Object Source

$env:Path = "C:\Program Files\Git\bin;$env:Path";
```
**This will put the "C:\Program Files\Git\bin" at the front. 

### Step 2: Deploy Materialize

Run the usual Terraform workflow:
**Make sure you have engough quota for the required VMs on Azure : https://portal.azure.com/?feature.msaljs=true#view/Microsoft_Azure_Capacity/QuotaMenuBlade/~/myQuotas

```bash
terraform workspace list  -- show the work spaces  
terraform workspace new [name] -- if you want to create a new work space 
terraform select  [name]  -- to switch work space 
terraform plan -var-file "terraform-sse7-2-au.tfvars.tfvars" -out "sse7-2-au.tfplan"
terraform init
terraform plan -var-file "[veriablefile].tfvars" -out "[name].tfplan"
terraform apply "[name].tfplan"
```

---

### Step 2.1: Re-Deploy Materialize Config Changes

For subsequent changes to an already-deployed environment (e.g. resizing `environmentd` via `environmentd_cpu_request`/`environmentd_memory_limit`, bumping node pool VM sizes, rotating the license key), re-plan/apply against the **same** workspace - no need to re-run `terraform init` or create a new workspace.

```bash
terraform workspace select [name]
terraform plan -var-file "[variablefile].tfvars" -out "[name].tfplan"
terraform apply "[name].tfplan"
```

**Review the plan output before applying** - confirm only the module(s) you intended to change show a diff (e.g. `module.materialize_instance`), not unrelated modules like `module.aks` or `module.database`.

#### How the cutover happens (no manual cleanup needed)

Changes to the Materialize CRD spec (`environmentd` CPU/memory, image version, license key, etc.) are **not applied in place**. The Materialize Kubernetes operator automatically:

1. Detects the spec diff and starts a **new generation** (`environmentd-2-0`, and any cluster replica pods `*-gen-2-0`) alongside the existing generation - you'll briefly see **two of everything** (`environmentd-1-0` and `environmentd-2-0`, etc.). This is expected, not an error.
2. Waits for the new generation to be healthy and stable for **10 minutes** (`status.conditions` shows `"Applying changes for generation N"`).
3. Automatically promotes the new generation (`status.activeGeneration` increments) and **tears down the old generation's pods** itself - no manual `kubectl delete` is needed.

You do **not** need to bump `force_rollout` for this - that variable only forces a new generation when *nothing* in the spec actually changed (e.g. to bounce pods with no config diff). A real config change, like a resource bump, triggers the rollout automatically.

#### Verifying the rollout

```bash
# Watch the CRD status until activeGeneration increments and the condition says "Successfully applied..."
kubectl get materialize main -n materialize-environment -o jsonpath='{.status.activeGeneration} {.status.conditions[0].message} {.status.conditions[0].status}'

# Confirm only the new generation's pods remain (old *-gen-1-0 pods should be gone)
kubectl get pods -n materialize-environment -o wide

# Confirm the new resource values took effect
kubectl get pod <new-environmentd-pod> -n materialize-environment -o jsonpath='{.spec.containers[0].resources}'

# Check for warnings - a FailedToUpdateEndpointSlices/probe-failure blip on the OLD pod at the
# exact cutover timestamp is expected teardown noise, not an error
kubectl get events -n materialize-environment --sort-by=.lastTimestamp --field-selector type=Warning
```

#### `environmentd-1-0` is still there well after 10 minutes - is that a problem?

Not necessarily. The 10-minute window only starts once **every** cluster in the environment reports fully hydrated and caught up. A deployment with several clusters (especially a large transform/materialized-view cluster with real data volume) can legitimately take much longer than a small demo environment with one tiny cluster - the new generation's replica has to rebuild its entire in-memory state from scratch, and that scales with data/compute size, not wall-clock time elapsed.

Before assuming something is stuck, check whether the new generation is actively making progress:

```bash
# Look for which cluster/collection is blocking the "caught up" check
kubectl logs <new-environmentd-pod> -n materialize-environment --since=1h | Select-String -Pattern "not caught up"

# Compare CPU/memory between the old and new replica for the cluster named above -
# meaningfully higher usage on the NEW replica confirms it's actively rehydrating,
# not stuck/crashed
kubectl top pod <old-replica-pod> <new-replica-pod> -n materialize-environment
```

If the blocking replica's CPU/memory is elevated and the logged `write_frontier` keeps advancing over successive checks, it's genuinely still hydrating - just let it continue. The old generation keeps serving 100% of traffic with zero downtime the entire time. Only investigate further if the new replica shows **no** progress (flat CPU, no restarts, no frontier movement) after a much longer window.

---

### Step 2.2: Upgrade the Materialize Version

Two variables control the version, both set per environment in the `.tfvars` file:

| Variable | What it is | Where it runs |
|---|---|---|
| `operator_version` | Helm chart version of the Materialize operator (`orchestratord`) | `materialize-operator` pod, system node pool |
| `environmentd_version` | Image tag of the database itself (`environmentd` and the `clusterd` replicas it launches) | `environmentd` and cluster replica pods, Materialize node pool |

```hcl
environmentd_version = "v26.45.1"
operator_version     = "v26.45.1" # keep >= environmentd_version
```

Rules:

- Keep `operator_version` **>=** `environmentd_version`. The operator can manage older `environmentd` versions within the supported range, but not newer ones. Setting both to the same value is the safe default.
- Both defaults in `variables.tf` are `v26.45.1`, but pin them explicitly in each `.tfvars` so a plan never shows an unreviewed version bump.
- Use **stable** releases only (no `-rc.N` suffix). List available chart versions with `helm repo add materialize https://materializeinc.github.io/materialize/; helm search repo materialize/materialize-operator --versions`.
- Review the [release notes](https://materialize.com/docs/releases/) between the current and target version for upgrade restrictions before applying to an environment that holds data.

Upgrade procedure (same workspace, no `terraform init` needed unless providers changed):

```bash
terraform workspace select [name]
terraform plan -var-file "[variablefile].tfvars" -out "[name].tfplan"
terraform apply "[name].tfplan"
```

The plan should show only `module.operator` (Helm release) and `module.materialize_instance` (the `Materialize` custom resource `environmentdImageRef`) changing. The operator is upgraded first, then the instance rolls to a new generation as described in Step 2.1. Instances use the `v1` CRD, so the changed image starts the rollout automatically (`request_rollout` is ignored on `v1`). To force a new generation with no spec change, set a new `force_rollout` UUID.

Downtime: with the default `WaitUntilReady` strategy the new generation hydrates alongside the old one, which keeps serving. Clients only see a brief connection drop at promotion, when `environmentd` and `balancerd` switch over (reconnect needed; expect seconds, not minutes). Rehydration time scales with data volume, and the node pool needs headroom for both generations at once.

Verify:

```bash
az aks get-credentials -g SGSSE7-3-AU-MATERIALIZE-RESOURCES -n <sgsse7-3-au-materialize-aks> --subscription 204be851-cdc4-4c59-b589-ce6c61ea3e63
helm list -n materialize
kubectl get materialize -A -o jsonpath='{.items[0].spec.environmentdImageRef}'
kubectl get pods -n materialize-environment
```

---

### Step 3: Accessing Materialize

#### Get the mz_system password

```bash
> terraform output -raw external_login_password_mz_system
> terraform output -raw grafana_admin_password

````

**Store this password seperately**

### Step 3: Setup sg user 
This is the uase account that would be used by the CI/CD to configure the views and materialize clusters for vairous domains. 

```
-- create the user account that would be used by the SQL scripts to setup the clusters/schema 
CREATE ROLE "sgfleet_user" WITH LOGIN PASSWORD '<change_me>';
ALTER ROLE sgfleet_user WITH SUPERUSER;

-- increase the mz_catalog_server cc to make the console more responsive 
ALTER CLUSTER mz_catalog_server SET (SIZE = '50cc');


```

### Step 4: Setup up the clusters 

Update the : .env.azure at : \MaterializeArchitecture-POC\miles-materialize-setup\.env.azure
Run the SQL scripts from : \miles-materialize-setup\scripts\ops\setup_materialize_azure.ps1


#### Security Model

This deployment implements a secure access model:

- **Public Access**: Only allowed via the Azure Load Balancer.
- **Direct Node Access**: **BLOCKED**. The AKS nodes are in private subnets and only accept traffic from within the VNet.

#### Access Methods


- **SQL Access**:

```bash
# Forward local port 6875 to the Materialize balancerd service
kubectl port-forward svc/mz<resource-id>-balancerd 6875:6875 -n materialize-environment
```

Then connect your PostgreSQL client to `localhost:6875`. The pgwire protocol is preserved through the TCP tunnel.

- **Console Access**:

```bash
# Forward local port 8080 to the Materialize console service
kubectl port-forward svc/mz<resource-id>-console 8080:8080 -n materialize-environment
```

Then open your browser to `http://localhost:8080`. HTTP traffic is preserved through the TCP tunnel.

**Note on Load Balancer Layer 4 operation:**
The Load Balancer operates at Layer 4 (TCP), forwarding connections without interpreting application-layer protocols. This works correctly for both pgwire (port 6875) and HTTP console access (port 8080), as both protocols run over TCP.

---

### Step 4: Accessing Grafana

Grafana is deployed in the `monitoring` namespace with pre-configured Materialize dashboards.


#### Login Credentials

- **Username:** `admin`
- **Password:** Retrieve from Terraform output:

```bash
terraform output -raw grafana_admin_password
```

#### Pre-configured Dashboards

The deployment includes Materialize dashboards under the "kubernetes/grafana" folder:

- **Environment Overview** - Overall Materialize environment health
- **Freshness Overview** - Data freshness monitoring

---

## Prometheus Resource Sizing Recommendations

The default Prometheus resource limits (500m CPU / 512Mi memory request, 1 CPU / 1Gi memory limit) are suitable for small deployments monitoring a single Materialize environment with default scrape intervals.

For production deployments, consider increasing resources based on:

- **Number of scrape targets**: More targets = more memory for time series
- **Scrape interval**: Lower intervals increase CPU and memory usage
- **Retention period**: Longer retention requires more storage and memory
- **Query complexity**: Heavy dashboard usage increases CPU needs

Example configuration for medium workload in `main.tf`:

```hcl
module "prometheus" {
  source = "../../../kubernetes/modules/prometheus"
  # ...
  server_resources = {
    requests = {
      cpu    = "1000m"
      memory = "2Gi"
    }
    limits = {
      cpu    = "2000m"
      memory = "4Gi"
    }
  }
  storage_size = "100Gi"
}
```

---

## Notes

* You can customize each module independently.
* To reduce cost in your demo environment, you can tweak VM sizes and database tiers in `main.tf`.
* Don't forget to destroy resources when finished:

```bash
terraform destroy
```
