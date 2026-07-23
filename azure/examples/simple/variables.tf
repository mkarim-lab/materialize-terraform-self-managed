variable "subscription_id" {
  description = "The ID of the Azure subscription"
  type        = string
}

variable "resource_group_name" {
  description = "The name of the resource group which will be created."
  type        = string
}

variable "location" {
  description = "The location of the Azure subscription"
  type        = string
  default     = "westus2"
}

variable "name_prefix" {
  description = "The prefix of the Azure subscription"
  type        = string
}

variable "tags" {
  description = "Tags to apply to resources created."
  type        = map(string)
}

variable "ingress_cidr_blocks" {
  description = "CIDR blocks that can reach the Azure LoadBalancer frontends."
  type        = list(string)
  default     = ["0.0.0.0/0"]
  nullable    = true

  validation {
    condition = var.ingress_cidr_blocks == null || alltrue([
      for cidr in var.ingress_cidr_blocks : can(cidrhost(cidr, 0))
    ])
    error_message = "All ingress_cidr_blocks must be valid CIDR notation (e.g., '10.0.0.0/8' or '0.0.0.0/0')."
  }
}

variable "license_key" {
  description = "Materialize license key"
  type        = string
  default     = null
  sensitive   = true
}

variable "force_rollout" {
  description = "UUID to force a rollout"
  type        = string
  default     = "00000000-0000-0000-0000-000000000001"
}

variable "request_rollout" {
  description = "UUID to request a rollout"
  type        = string
  default     = "00000000-0000-0000-0000-000000000001"
}

variable "k8s_apiserver_authorized_networks" {
  description = "List of authorized IP ranges that can access the Kubernetes API server when public access is available. Defaults to ['0.0.0.0/0'] (allow all). For production, restrict to specific IPs (e.g., ['203.0.113.0/24'])"
  type        = list(string)
  default     = ["0.0.0.0/0"] # Explicit default: allow all IPs
  nullable    = true

  validation {
    condition = (
      var.k8s_apiserver_authorized_networks == null ||
      alltrue([
        for cidr in var.k8s_apiserver_authorized_networks :
        can(cidrhost(cidr, 0))
      ])
    )
    error_message = "All k8s_apiserver_authorized_networks must be valid CIDR blocks (e.g., '203.0.113.0/24')."
  }
}


variable "internal_load_balancer" {
  description = "Whether to use an internal load balancer"
  type        = bool
  default     = true
}

variable "enable_observability" {
  description = "Enable Prometheus and Grafana monitoring stack for Materialize"
  type        = bool
  default     = false
}

variable "existing_vnet_name" {
  description = "Name of the existing VNet to use"
  type        = string
}

variable "existing_vnet_resource_group" {
  description = "Resource group of the existing VNet"
  type        = string
}

variable "existing_aks_subnet_name" {
  description = "Name of the existing AKS subnet"
  type        = string
}

variable "existing_postgres_subnet_name" {
  description = "Name of the existing PostgreSQL subnet"
  type        = string
}

variable "dns_subscription_id" {
  description = "Subscription ID where the private DNS zone lives"
  type        = string
}

variable "dns_zone_resource_group" {
  description = "Resource group of the private DNS zone"
  type        = string
}

variable "default_node_pool_max_pods" {
  description = "Max pods per node for the AKS default (system) node pool. Lower this to reduce Azure CNI IP pre-allocation on constrained subnets."
  type        = number
  default     = 30
  nullable    = false

  validation {
    condition     = var.default_node_pool_max_pods >= 10 && var.default_node_pool_max_pods <= 250
    error_message = "default_node_pool_max_pods must be between 10 and 250 (Azure CNI limits)."
  }
}

variable "materialize_node_pool_max_pods" {
  description = "Max pods per node for the Materialize node pool. Lower this to reduce Azure CNI IP pre-allocation on constrained subnets."
  type        = number
  default     = 30
  nullable    = false

  validation {
    condition     = var.materialize_node_pool_max_pods >= 10 && var.materialize_node_pool_max_pods <= 250
    error_message = "materialize_node_pool_max_pods must be between 10 and 250 (Azure CNI limits)."
  }
}

variable "default_node_pool_min_count" {
  description = "Minimum node count for the AKS default (system) node pool autoscaler. Lower this to reduce Azure CNI IP pre-allocation on constrained subnets."
  type        = number
  default     = 2
  nullable    = false

  validation {
    condition     = var.default_node_pool_min_count >= 1
    error_message = "default_node_pool_min_count must be at least 1."
  }
}

variable "default_node_pool_max_count" {
  description = "Maximum node count for the AKS default (system) node pool autoscaler. Lower this to reduce Azure CNI IP pre-allocation on constrained subnets."
  type        = number
  default     = 5
  nullable    = false

  validation {
    condition     = var.default_node_pool_max_count >= var.default_node_pool_min_count
    error_message = "default_node_pool_max_count must be greater than or equal to default_node_pool_min_count."
  }
}

variable "materialize_node_pool_min_nodes" {
  description = "Minimum node count for the Materialize node pool autoscaler. Lower this to reduce Azure CNI IP pre-allocation on constrained subnets."
  type        = number
  default     = 2
  nullable    = false

  validation {
    condition     = var.materialize_node_pool_min_nodes >= 1
    error_message = "materialize_node_pool_min_nodes must be at least 1."
  }
}

variable "materialize_node_pool_max_nodes" {
  description = "Maximum node count for the Materialize node pool autoscaler. Lower this to reduce Azure CNI IP pre-allocation on constrained subnets."
  type        = number
  default     = 5
  nullable    = false

  validation {
    condition     = var.materialize_node_pool_max_nodes >= var.materialize_node_pool_min_nodes
    error_message = "materialize_node_pool_max_nodes must be greater than or equal to materialize_node_pool_min_nodes."
  }
}

# Azure CNI Overlay (https://learn.microsoft.com/en-us/azure/aks/azure-cni-overlay):
# with overlay enabled, pods get IPs from pod_cidr (a virtual, non-VNet-routed
# range) instead of the AKS subnet, so max_pods no longer consumes subnet IPs.
# This is what allows this example to run on a small/constrained AKS subnet.
#
# PROD recommendation: pick a pod_cidr that doesn't overlap the VNet,
# service_cidr, or any peered/on-prem network, especially if multiple clusters
# in your estate are peered to the same hub VNet. Set network_plugin_mode to
# null (standard Azure CNI) instead if PROD requires pods to be directly
# routable/reachable from the VNet (e.g. on-prem systems reaching pod IPs
# directly) — but then the subnet must be sized using the
# (max_nodes + surge) * (max_pods + 1) formula per node pool.
variable "pod_cidr" {
  description = "Pod CIDR for Azure CNI Overlay mode. Must not overlap the VNet, service_cidr, or any peered network."
  type        = string
  default     = "10.244.0.0/16"
  nullable    = false

  validation {
    condition     = can(cidrhost(var.pod_cidr, 0))
    error_message = "pod_cidr must be a valid CIDR block (e.g., '10.244.0.0/16')."
  }
}

variable "network_plugin_mode" {
  description = "Set to \"overlay\" to enable Azure CNI Overlay (pods use pod_cidr instead of consuming AKS subnet IPs). Set to null for standard Azure CNI (pods consume subnet IPs directly)."
  type        = string
  default     = "overlay"

  validation {
    condition     = var.network_plugin_mode == null || var.network_plugin_mode == "overlay"
    error_message = "network_plugin_mode must be either null (standard Azure CNI) or 'overlay'."
  }
}
