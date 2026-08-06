provider "azurerm" {
  # Set the Azure subscription ID here or use the AZURE_SUBSCRIPTION_ID environment variable
  subscription_id = var.subscription_id

  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
    key_vault {
      purge_soft_delete_on_destroy    = true
      recover_soft_deleted_key_vaults = false
    }
  }
}

provider "kubernetes" {
  host                   = module.aks.cluster_endpoint
  client_certificate     = base64decode(module.aks.kube_config[0].client_certificate)
  client_key             = base64decode(module.aks.kube_config[0].client_key)
  cluster_ca_certificate = base64decode(module.aks.kube_config[0].cluster_ca_certificate)
}

provider "helm" {
  kubernetes {
    host                   = module.aks.cluster_endpoint
    client_certificate     = base64decode(module.aks.kube_config[0].client_certificate)
    client_key             = base64decode(module.aks.kube_config[0].client_key)
    cluster_ca_certificate = base64decode(module.aks.kube_config[0].cluster_ca_certificate)
  }
}

# lazy_load = true lets alekc/kubectl v2.4.0+ defer kubeconfig resolution
# (which is strict at provider-configure since v2.3.0) until first use. Without
# it, same-root cluster-plus-manifests applies fail at plan with an empty REST
# config because module.aks outputs are unknown before the cluster exists. See:
# https://registry.terraform.io/providers/alekc/kubectl/latest/docs#troubleshooting
provider "kubectl" {
  host                   = module.aks.cluster_endpoint
  client_certificate     = base64decode(module.aks.kube_config[0].client_certificate)
  client_key             = base64decode(module.aks.kube_config[0].client_key)
  cluster_ca_certificate = base64decode(module.aks.kube_config[0].cluster_ca_certificate)

  load_config_file = false
  lazy_load        = true

  # Retries kubectl_manifest applies with exponential backoff. This is needed
  # because the Materialize CRD uses a conversion webhook served by the
  # materialize-operator pod: right after the operator is deployed, AKS's
  # control-plane-to-pod proxy path (and/or the webhook server itself) can
  # take a bit to become reachable, causing a transient
  # "504 Gateway Timeout" on the very first apply. apply_retry_count makes
  # the provider retry instead of failing immediately.
  apply_retry_count = 5
}


locals {
  vnet_config = {
    address_space                      = "20.0.0.0/16"
    aks_subnet_cidr                    = "20.0.0.0/20"
    postgres_subnet_cidr               = "20.0.16.0/24"
    enable_api_server_vnet_integration = !var.use_existing_network
    api_server_subnet_cidr             = "20.0.32.0/27" # keeping atleast 32 IPs reserved for API server and related services used in delegation might reduce it later.
  }

  aks_config = {
    kubernetes_version         = "1.34"
    service_cidr               = "20.1.0.0/16"
    enable_azure_monitor       = false
    log_analytics_workspace_id = null
  }

  node_pool_config = {
    vm_size              = var.materialize_node_pool_vm_size
    auto_scaling_enabled = var.materialize_node_pool_auto_scaling_enabled
    min_nodes            = var.materialize_node_pool_min_nodes
    max_nodes            = var.materialize_node_pool_max_nodes
    node_count           = var.materialize_node_pool_node_count
    disk_size_gb         = 100
    swap_enabled         = true
  }

  database_config = {
    sku_name                      = "GP_Standard_D2s_v3"
    postgres_version              = "15"
    storage_mb                    = 32768
    backup_retention_days         = 7
    administrator_login           = "materialize"
    administrator_password        = null # Will generate random password
    database_name                 = "materialize"
    public_network_access_enabled = false
  }

  storage_container_name = "materialize"

  database_statement_timeout = "15min"

  metadata_backend_url = format(
    "postgres://%s:%s@%s/%s?sslmode=require&options=-c%%20statement_timeout%%3D%s",
    module.database.administrator_login,
    urlencode(module.database.administrator_password),
    module.database.server_fqdn,
    local.database_config.database_name,
    local.database_statement_timeout
  )

  persist_backend_url = format(
    "%s%s",
    module.storage.primary_blob_endpoint,
    module.storage.container_name,
  )

  materialize_instance_namespace = "materialize-environment"
  materialize_instance_name      = "main"

  # Common node scheduling configuration
  generic_node_labels = {
    "workload" = "generic"
  }

  materialize_node_labels = {
    "workload" = "materialize-instance"
  }

  materialize_node_taints = [
    {
      key    = "materialize.cloud/workload"
      value  = "materialize-instance"
      effect = "NoSchedule"
    }
  ]

  materialize_tolerations = [
    {
      key      = "materialize.cloud/workload"
      value    = "materialize-instance"
      operator = "Equal"
      effect   = "NoSchedule"
    }
  ]

  # https://learn.microsoft.com/en-us/azure/aks/concepts-storage#storage-classes
  storage_class = "managed-csi"
}


resource "azurerm_resource_group" "materialize" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

# ============================================================================
# Existing VNet/Subnet reuse (bring-your-own network)
# ============================================================================
# Looked up only when use_existing_network = true. The Postgres private DNS
# zone is referenced directly via var.existing_postgres_private_dns_zone_id
# (it may live in a different subscription) and is NOT looked up here - it
# must already be linked to the existing VNet.

data "azurerm_virtual_network" "existing" {
  count               = var.use_existing_network ? 1 : 0
  name                = var.existing_vnet_name
  resource_group_name = var.existing_vnet_resource_group
}

data "azurerm_subnet" "existing_aks" {
  count                = var.use_existing_network ? 1 : 0
  name                 = var.existing_aks_subnet_name
  virtual_network_name = var.existing_vnet_name
  resource_group_name  = var.existing_vnet_resource_group
}

data "azurerm_subnet" "existing_postgres" {
  count                = var.use_existing_network ? 1 : 0
  name                 = var.existing_postgres_subnet_name
  virtual_network_name = var.existing_vnet_name
  resource_group_name  = var.existing_vnet_resource_group
}

# Bridges the two networking paths (module-created vs. existing) into a single
# set of locals consumed by every downstream module below.
locals {
  net_vnet_id               = var.use_existing_network ? data.azurerm_virtual_network.existing[0].id : module.networking[0].vnet_id
  net_vnet_name             = var.use_existing_network ? var.existing_vnet_name : module.networking[0].vnet_name
  net_vnet_resource_group   = var.use_existing_network ? var.existing_vnet_resource_group : azurerm_resource_group.materialize.name
  net_aks_subnet_id         = var.use_existing_network ? data.azurerm_subnet.existing_aks[0].id : module.networking[0].aks_subnet_id
  net_aks_subnet_name       = var.use_existing_network ? var.existing_aks_subnet_name : module.networking[0].aks_subnet_name
  net_postgres_subnet_id    = var.use_existing_network ? data.azurerm_subnet.existing_postgres[0].id : module.networking[0].postgres_subnet_id
  net_private_dns_zone_id   = var.use_existing_network ? var.existing_postgres_private_dns_zone_id : module.networking[0].private_dns_zone_id
  net_nat_gateway_public_ip = var.use_existing_network ? null : module.networking[0].nat_gateway_public_ip
  net_api_server_subnet_id  = var.use_existing_network ? null : module.networking[0].api_server_subnet_id
}

# Fails fast at plan time if use_existing_network is true but any required
# existing_* value is missing, or if the DNS zone ID looks like it doesn't
# match the subscription/resource group it's supposed to come from.
check "existing_network_requires_all_fields" {
  assert {
    condition = !var.use_existing_network || (
      var.existing_vnet_name != null &&
      var.existing_vnet_resource_group != null &&
      var.existing_aks_subnet_name != null &&
      var.existing_postgres_subnet_name != null &&
      var.existing_postgres_private_dns_zone_id != null
    )
    error_message = "When use_existing_network is true, existing_vnet_name, existing_vnet_resource_group, existing_aks_subnet_name, existing_postgres_subnet_name, and existing_postgres_private_dns_zone_id must all be set."
  }
}

check "dns_zone_id_matches_subscription_and_rg" {
  assert {
    condition = (
      var.existing_postgres_private_dns_zone_id == null ||
      var.dns_subscription_id == null ||
      strcontains(var.existing_postgres_private_dns_zone_id, var.dns_subscription_id)
    )
    error_message = "existing_postgres_private_dns_zone_id does not appear to contain dns_subscription_id - check for a copy-paste mistake."
  }
  assert {
    condition = (
      var.existing_postgres_private_dns_zone_id == null ||
      var.dns_zone_resource_group == null ||
      strcontains(lower(var.existing_postgres_private_dns_zone_id), lower(var.dns_zone_resource_group))
    )
    error_message = "existing_postgres_private_dns_zone_id does not appear to contain dns_zone_resource_group - check for a copy-paste mistake."
  }
}


module "networking" {
  count  = var.use_existing_network ? 0 : 1
  source = "../../modules/networking"

  resource_group_name                = azurerm_resource_group.materialize.name
  location                           = var.location
  prefix                             = var.name_prefix
  vnet_address_space                 = local.vnet_config.address_space
  aks_subnet_cidr                    = local.vnet_config.aks_subnet_cidr
  postgres_subnet_cidr               = local.vnet_config.postgres_subnet_cidr
  enable_api_server_vnet_integration = local.vnet_config.enable_api_server_vnet_integration
  api_server_subnet_cidr             = local.vnet_config.api_server_subnet_cidr

  tags = var.tags

  depends_on = [azurerm_resource_group.materialize]
}

# AKS Cluster with Default Node Pool
module "aks" {
  source = "../../modules/aks"

  resource_group_name      = azurerm_resource_group.materialize.name
  kubernetes_version       = local.aks_config.kubernetes_version
  service_cidr             = local.aks_config.service_cidr
  location                 = var.location
  prefix                   = var.name_prefix
  vnet_name                = local.net_vnet_name
  vnet_resource_group_name = local.net_vnet_resource_group
  subnet_name              = local.net_aks_subnet_name
  subnet_id                = local.net_aks_subnet_id
  subscription_id          = var.subscription_id

  enable_api_server_vnet_integration = local.vnet_config.enable_api_server_vnet_integration
  k8s_apiserver_authorized_networks  = var.use_existing_network ? var.k8s_apiserver_authorized_networks : concat(var.k8s_apiserver_authorized_networks, ["${local.net_nat_gateway_public_ip}/32"])
  api_server_subnet_id               = local.net_api_server_subnet_id

  # Azure CNI Overlay (optional) - see network_plugin_mode/pod_cidr variables
  network_plugin_mode = var.network_plugin_mode
  pod_cidr            = var.pod_cidr

  # No NAT Gateway is created when reusing an existing VNet (module.networking is
  # skipped), so egress must rely on the existing subnet's own routing (UDR/firewall)
  # instead of a NAT Gateway.
  outbound_type = var.use_existing_network ? "userDefinedRouting" : "userAssignedNATGateway"

  # Default node pool with autoscaling (runs all workloads except Materialize)
  default_node_pool_vm_size             = var.default_node_pool_vm_size
  default_node_pool_enable_auto_scaling = true
  default_node_pool_min_count           = 2
  default_node_pool_max_count           = 5
  default_node_pool_node_labels         = local.generic_node_labels
  default_node_pool_max_pods            = var.default_node_pool_max_pods

  # Optional: Enable monitoring
  enable_azure_monitor       = local.aks_config.enable_azure_monitor
  log_analytics_workspace_id = local.aks_config.log_analytics_workspace_id

  tags = var.tags

  depends_on = [azurerm_resource_group.materialize]
}

# Materialize-dedicated node pool with taints (via labels on Azure)
module "materialize_nodepool" {
  source = "../../modules/nodepool"

  prefix     = var.name_prefix
  cluster_id = module.aks.cluster_id
  subnet_id  = local.net_aks_subnet_id

  # Workload-specific configuration
  autoscaling_config = {
    enabled    = local.node_pool_config.auto_scaling_enabled
    min_nodes  = local.node_pool_config.min_nodes
    max_nodes  = local.node_pool_config.max_nodes
    node_count = local.node_pool_config.node_count
  }

  vm_size      = local.node_pool_config.vm_size
  disk_size_gb = local.node_pool_config.disk_size_gb
  swap_enabled = local.node_pool_config.swap_enabled

  labels = local.materialize_node_labels

  # Materialize-specific taint to isolate workloads
  # https://github.com/Azure/AKS/issues/2934
  # Note: Once applied, these cannot be manually removed due to AKS webhook restrictions
  node_taints = local.materialize_node_taints

  tags = var.tags

  depends_on = [azurerm_resource_group.materialize]
}


module "database" {
  source = "../../modules/database"

  depends_on = [module.networking]

  # Database configuration using new structure
  databases = [
    {
      name      = local.database_config.database_name
      charset   = "UTF8"
      collation = "en_US.utf8"
    }
  ]

  # Administrator configuration
  administrator_login = local.database_config.administrator_login

  # Infrastructure configuration
  resource_group_name = azurerm_resource_group.materialize.name
  location            = var.location
  prefix              = var.name_prefix
  subnet_id           = local.net_postgres_subnet_id
  private_dns_zone_id = local.net_private_dns_zone_id

  # Database server configuration
  sku_name                      = local.database_config.sku_name
  postgres_version              = local.database_config.postgres_version
  storage_mb                    = local.database_config.storage_mb
  backup_retention_days         = local.database_config.backup_retention_days
  public_network_access_enabled = local.database_config.public_network_access_enabled

  tags = var.tags
}

module "storage" {
  source = "../../modules/storage"

  resource_group_name            = azurerm_resource_group.materialize.name
  location                       = var.location
  prefix                         = var.name_prefix
  workload_identity_principal_id = module.aks.workload_identity_principal_id
  subnets                        = [local.net_aks_subnet_id]
  container_name                 = local.storage_container_name

  public_network_access_enabled = var.storage_public_network_access_enabled

  # Workload identity federation configuration
  workload_identity_id      = module.aks.workload_identity_id
  oidc_issuer_url           = module.aks.cluster_oidc_issuer_url
  service_account_namespace = local.materialize_instance_namespace
  service_account_name      = local.materialize_instance_name

  storage_account_tags = var.tags

  depends_on = [azurerm_resource_group.materialize]
}

resource "random_password" "external_login_password_mz_system" {
  length           = 16
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

# Deploy custom CoreDNS with TTL 0 (AKS's coredns doesn't support disabling caching)
module "coredns" {
  source             = "../../../kubernetes/modules/coredns"
  node_selector      = local.generic_node_labels
  kubeconfig_data    = module.aks.kube_config_raw
  cluster_identifier = module.aks.cluster_name
  depends_on = [
    module.aks,
    module.networking,
  ]
}

module "cert_manager" {
  source = "../../../kubernetes/modules/cert-manager"

  node_selector = local.generic_node_labels

  depends_on = [
    module.aks,
    module.networking,
    module.coredns,
  ]
}

module "self_signed_cluster_issuer" {
  source = "../../../kubernetes/modules/self-signed-cluster-issuer"

  name_prefix = var.name_prefix

  depends_on = [
    module.cert_manager,
  ]
}

module "operator" {
  source = "../../modules/operator"

  name_prefix = var.name_prefix
  location    = var.location

  instance_pod_tolerations = local.materialize_tolerations
  instance_node_selector   = local.materialize_node_labels

  # node selector for operator and metrics-server workloads
  operator_node_selector = local.generic_node_labels

  # Enable Prometheus scrape annotations when observability is enabled
  helm_values = var.enable_observability ? {
    observability = {
      enabled = true
      prometheus = {
        scrapeAnnotations = {
          enabled = true
        }
      }
    }
  } : {}
  enable_network_policies = true
  depends_on = [
    module.aks,
    module.database,
    module.storage,
    module.coredns,
    module.cert_manager,
  ]
}

module "prometheus" {
  count  = var.enable_observability ? 1 : 0
  source = "../../../kubernetes/modules/prometheus"

  namespace        = "monitoring"
  create_namespace = false # operator creates the "monitoring" namespace
  node_selector    = local.generic_node_labels
  storage_class    = local.storage_class

  depends_on = [
    module.operator,
    module.aks,
    module.coredns,
  ]
}

module "grafana" {
  count  = var.enable_observability ? 1 : 0
  source = "../../../kubernetes/modules/grafana"

  namespace     = "monitoring"
  storage_class = local.storage_class
  # operator creates the "monitoring" namespace
  create_namespace = false
  prometheus_url   = module.prometheus[0].prometheus_url
  node_selector    = local.generic_node_labels

  depends_on = [
    module.prometheus,
  ]
}

module "materialize_instance" {
  source                  = "../../../kubernetes/modules/materialize-instance"
  instance_name           = local.materialize_instance_name
  instance_namespace      = local.materialize_instance_namespace
  metadata_backend_url    = local.metadata_backend_url
  persist_backend_url     = local.persist_backend_url
  enable_network_policies = true

  # Rollout configuration
  force_rollout   = var.force_rollout
  request_rollout = var.request_rollout

  # The password for the external login to the Materialize instance
  authenticator_kind                = "Password"
  external_login_password_mz_system = random_password.external_login_password_mz_system.result

  # Azure workload identity annotations for service account
  service_account_annotations = {
    "azure.workload.identity/client-id" = module.aks.workload_identity_client_id
  }
  pod_labels = {
    "azure.workload.identity/use" = "true"
  }

  license_key = var.license_key

  issuer_ref = {
    name = module.self_signed_cluster_issuer.issuer_name
    kind = "ClusterIssuer"
  }

  # System parameters for the Materialize instance
  # See: https://materialize.com/docs/self-managed-deployments/configuration-system-parameters/
  # Example settings:
  #   max_connections               = "1000"
  #   allowed_cluster_replica_sizes = "'25cc', '50cc', '100cc', '200cc', '400cc', '800cc', '1600cc', '3200cc'"
  #   max_clusters                  = "10"
  #   max_sources                   = "50"
  #   max_sinks                     = "50"
  system_parameters = {}

  # balancerd's 256Mi default can OOM-kill under high connection load; raise
  # to 2Gi to give it headroom.
  balancer_memory_request = "2Gi"
  balancer_memory_limit   = "2Gi"

  depends_on = [
    module.aks,
    module.database,
    module.storage,
    module.networking,
    module.self_signed_cluster_issuer,
    module.operator,
    module.materialize_nodepool,
    module.coredns,
  ]
}

module "load_balancers" {
  source = "../../modules/load_balancers"

  instance_name       = local.materialize_instance_name
  namespace           = local.materialize_instance_namespace
  resource_id         = module.materialize_instance.instance_resource_id
  internal            = var.internal_load_balancer
  ingress_cidr_blocks = var.internal_load_balancer ? null : var.ingress_cidr_blocks

  depends_on = [
    module.materialize_instance,
  ]
}
