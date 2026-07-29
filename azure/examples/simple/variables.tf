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

  validation {
    condition = alltrue([
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

# ============================================================================
# Existing VNet/Subnet reuse (bring-your-own network)
# ============================================================================

variable "use_existing_network" {
  description = "Whether to reuse an existing VNet/subnets instead of creating new networking resources. When true, existing_vnet_name, existing_vnet_resource_group, existing_aks_subnet_name, existing_postgres_subnet_name, and existing_postgres_private_dns_zone_id must all be set. API Server VNet Integration is disabled in this mode."
  type        = bool
  default     = false
  nullable    = false
}

variable "existing_vnet_name" {
  description = "Name of the existing VNet to deploy into. Required when use_existing_network is true."
  type        = string
  default     = null
}

variable "existing_vnet_resource_group" {
  description = "Resource group containing the existing VNet. Required when use_existing_network is true."
  type        = string
  default     = null
}

variable "existing_aks_subnet_name" {
  description = "Name of the existing subnet used for the AKS cluster and node pools. With traditional Azure CNI (network_plugin_mode = null) this subnet must have enough free IPs for nodes AND pods; with network_plugin_mode = \"overlay\" it only needs IPs for nodes. Required when use_existing_network is true."
  type        = string
  default     = null
}

variable "existing_postgres_subnet_name" {
  description = "Name of the existing subnet used for the PostgreSQL Flexible Server. Must be delegated to Microsoft.DBforPostgreSQL/flexibleServers and contain no other resources. Required when use_existing_network is true."
  type        = string
  default     = null
}

variable "existing_postgres_private_dns_zone_id" {
  description = "Full Azure resource ID of the existing Private DNS Zone used for PostgreSQL name resolution (e.g. privatelink.postgres.database.azure.com). May live in a different subscription than the rest of this deployment. Must already be linked to the existing VNet - this module does not create a VNet link. Required when use_existing_network is true."
  type        = string
  default     = null
}

variable "dns_subscription_id" {
  description = "Subscription ID that owns existing_postgres_private_dns_zone_id. Used only to sanity-check the zone ID (catches copy-paste mistakes); not used to configure any provider."
  type        = string
  default     = null
}

variable "dns_zone_resource_group" {
  description = "Resource group that owns existing_postgres_private_dns_zone_id. Used only to sanity-check the zone ID (catches copy-paste mistakes); not used to configure any provider."
  type        = string
  default     = null
}

# ============================================================================
# AKS networking mode
# ============================================================================

variable "network_plugin_mode" {
  description = "AKS network plugin mode. Set to \"overlay\" to use Azure CNI Overlay, where pods get IPs from pod_cidr instead of consuming IPs from the VNet subnet. Leave null for traditional Azure CNI. Recommended (and may be required) when reusing a small existing_aks_subnet_name."
  type        = string
  default     = null

  validation {
    condition     = var.network_plugin_mode == null || var.network_plugin_mode == "overlay"
    error_message = "network_plugin_mode must be null or \"overlay\"."
  }
}

variable "pod_cidr" {
  description = "CIDR range for pod IPs when network_plugin_mode is \"overlay\". Must not overlap the VNet, service_cidr (20.1.0.0/16), or any peered/on-prem network. Microsoft recommends a CGNAT range such as 100.64.0.0/16, since it is rarely used in customer VNets or on-prem networks. Required when network_plugin_mode is \"overlay\"."
  type        = string
  default     = null

  validation {
    condition     = var.pod_cidr == null || can(cidrhost(var.pod_cidr, 0))
    error_message = "pod_cidr must be a valid CIDR block (e.g. '100.64.0.0/16')."
  }
}

variable "default_node_pool_max_pods" {
  description = "Maximum number of pods per node in the default node pool. Set at node pool creation time and cannot be changed later without recreating the node pool. Lower this (e.g. 15-20) when reusing a small existing_aks_subnet_name with traditional Azure CNI (network_plugin_mode = null), since Azure reserves one subnet IP per pod slot per node regardless of actual pod count. Leave null to use the AKS/provider default (30 for Azure CNI)."
  type        = number
  default     = null

  validation {
    condition     = var.default_node_pool_max_pods == null || var.default_node_pool_max_pods > 0
    error_message = "default_node_pool_max_pods must be greater than 0 when set."
  }
}
