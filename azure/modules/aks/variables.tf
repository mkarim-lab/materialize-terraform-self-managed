variable "resource_group_name" {
  description = "The name of the resource group"
  type        = string
  nullable    = false
}

variable "location" {
  description = "The location where resources will be created"
  type        = string
  nullable    = false
}

variable "prefix" {
  description = "Prefix to be used for resource names"
  type        = string
  nullable    = false
}

variable "vnet_name" {
  description = "The name of the virtual network."
  type        = string
  nullable    = false
}

variable "vnet_resource_group_name" {
  description = "Resource group containing the VNet/subnets used by AKS (for the Network Contributor role assignment scope). Defaults to resource_group_name when the VNet lives in the same resource group as the AKS cluster; set explicitly when reusing an existing VNet in a different resource group."
  type        = string
  default     = null
}

variable "subscription_id" {
  description = "The Azure subscription ID, used to build the Network Contributor role assignment scope. Passed in explicitly (rather than looked up via a data source) so the scope stays statically known at plan time, even while other unrelated resources in the same apply are still pending."
  type        = string
  nullable    = false
}

variable "subnet_name" {
  description = "The name of the subnet for AKS"
  type        = string
  nullable    = false
}

variable "subnet_id" {
  description = "The ID of the subnet for AKS"
  type        = string
  nullable    = false
}

variable "service_cidr" {
  description = "CIDR range for Kubernetes services"
  type        = string

  validation {
    condition     = can(cidrhost(var.service_cidr, 10))
    error_message = "service_cidr must be a valid CIDR block (e.g., '10.2.0.0/16')."
  }
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default     = {}
}

variable "kubernetes_version" {
  description = "Version of Kubernetes to use for the AKS cluster"
  type        = string
  default     = "1.34"
  nullable    = false
}

variable "default_node_pool_vm_size" {
  description = "VM size for the default node pool (system node pool)"
  type        = string
  default     = "Standard_D2s_v3"
  nullable    = false
}

variable "default_node_pool_enable_auto_scaling" {
  description = "Enable auto scaling for the default node pool"
  type        = bool
  default     = true
  nullable    = false
}

variable "default_node_pool_node_count" {
  description = "Number of nodes in the default node pool (used only when auto scaling is disabled)"
  type        = number
  default     = 1

  validation {
    condition = (
      var.default_node_pool_enable_auto_scaling ||
      var.default_node_pool_node_count > 0
    )
    error_message = "default_node_pool_node_count must be greater than 0 when auto scaling is disabled."
  }
}

variable "default_node_pool_min_count" {
  description = "Minimum number of nodes in the default node pool (used only when auto scaling is enabled)"
  type        = number
  default     = 1

  validation {
    condition = (
      !var.default_node_pool_enable_auto_scaling ||
      var.default_node_pool_min_count > 0
    )
    error_message = "default_node_pool_min_count must be greater than 0 when auto scaling is enabled."
  }
}

variable "default_node_pool_max_count" {
  description = "Maximum number of nodes in the default node pool (used only when auto scaling is enabled)"
  type        = number
  default     = 5

  validation {
    condition = (
      !var.default_node_pool_enable_auto_scaling ||
      var.default_node_pool_max_count > 0
    )
    error_message = "default_node_pool_max_count must be greater than 0 when auto scaling is enabled."
  }

  validation {
    condition = (
      !var.default_node_pool_enable_auto_scaling ||
      var.default_node_pool_max_count >= var.default_node_pool_min_count
    )
    error_message = "default_node_pool_max_count must be greater than or equal to default_node_pool_min_count when auto scaling is enabled."
  }
}

variable "default_node_pool_os_disk_size_gb" {
  description = "OS disk size in GB for the default node pool"
  type        = number
  default     = 100
  nullable    = false
}

variable "default_node_pool_max_pods" {
  description = "Maximum number of pods per node in the default node pool. This is set at node pool creation time and cannot be changed later without recreating the node pool. Lower this (e.g. to 15-20) when the AKS subnet is small and using traditional Azure CNI, since Azure reserves one subnet IP per pod slot per node regardless of actual pod count. Leave null to use the AKS/provider default (30 for Azure CNI)."
  type        = number
  default     = null

  validation {
    condition     = var.default_node_pool_max_pods == null || var.default_node_pool_max_pods > 0
    error_message = "default_node_pool_max_pods must be greater than 0 when set."
  }
}

variable "default_node_pool_node_labels" {
  description = "Node labels for the default node pool"
  type        = map(string)
  default     = {}
  nullable    = false
}


variable "enable_azure_monitor" {
  description = "Enable Azure Monitor for the AKS cluster"
  type        = bool
  default     = false
  nullable    = false
}

variable "log_analytics_workspace_id" {
  description = "Log Analytics workspace ID for Azure Monitor (required if enable_azure_monitor is true)"
  type        = string
  default     = null
}

variable "enable_azure_ad_rbac" {
  description = "Enable Azure Active Directory integration for RBAC"
  type        = bool
  default     = false
  nullable    = false
}

variable "azure_ad_admin_group_object_ids" {
  description = "List of Azure AD group object IDs that will have admin access to the cluster, applied only if enable_azure_ad_rbac is true"
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for id in var.azure_ad_admin_group_object_ids :
      can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", id))
    ])
    error_message = "All azure_ad_admin_group_object_ids must be valid UUIDs (e.g., '12345678-1234-1234-1234-123456789012')."
  }
}

# Limitations of using azure cni powered by cilium
# https://learn.microsoft.com/en-us/azure/aks/azure-cni-powered-by-cilium#limitations
variable "network_plugin" {
  description = "Network plugin to use (azure or kubenet)"
  type        = string
  default     = "azure"
  validation {
    condition     = contains(["azure", "kubenet"], var.network_plugin)
    error_message = "Network plugin must be either 'azure' or 'kubenet'."
  }
}

variable "network_policy" {
  description = "Network policy to use (azure, calico, cilium, or null). Note: Azure Network Policy Manager is deprecated; migrate to cilium by 2028."
  type        = string
  default     = "cilium"
  validation {
    condition     = var.network_policy == null || contains(["azure", "calico", "cilium"], var.network_policy)
    error_message = "Network policy must be either 'azure', 'calico', 'cilium', or null."
  }
}

variable "network_data_plane" {
  description = "Network data plane to use (azure or cilium). When using cilium network policy, this must be set to cilium."
  type        = string
  default     = "cilium"
  validation {
    condition     = contains(["azure", "cilium"], var.network_data_plane)
    error_message = "Network data plane must be either 'azure' or 'cilium'."
  }
}

variable "network_plugin_mode" {
  description = "AKS network plugin mode. Set to 'overlay' to use Azure CNI Overlay, where pods get IPs from pod_cidr instead of consuming IPs from the VNet subnet. Leave null for traditional Azure CNI."
  type        = string
  default     = null

  validation {
    condition     = var.network_plugin_mode == null || var.network_plugin_mode == "overlay"
    error_message = "network_plugin_mode must be null or 'overlay'."
  }
}

variable "pod_cidr" {
  description = "CIDR range for pod IPs when network_plugin_mode is 'overlay'. Must not overlap the VNet address space, service_cidr, or any peered/on-prem network. Required when network_plugin_mode is 'overlay'."
  type        = string
  default     = null

  validation {
    condition     = var.pod_cidr == null || can(cidrhost(var.pod_cidr, 0))
    error_message = "pod_cidr must be a valid CIDR block (e.g. '100.64.0.0/16')."
  }
}

variable "disk_driver_enabled" {
  description = "Whether Disk CSI Driver is enabled"
  type        = bool
  default     = true
  nullable    = false
}

variable "dns_service_ip" {
  description = "IP address within the service CIDR that will be used by cluster service discovery (kube-dns). If not specified, will be calculated automatically."
  type        = string
  default     = null

  validation {
    condition = (
      var.dns_service_ip == null ||
      can(regex("^(?:[0-9]{1,3}\\.){3}[0-9]{1,3}$", var.dns_service_ip))
    )
    error_message = "dns_service_ip must be a valid IP address or null."
  }
}

variable "load_balancer_sku" {
  description = "SKU of the Load Balancer used for this Kubernetes Cluster"
  type        = string
  default     = "standard"
  validation {
    condition     = contains(["basic", "standard"], var.load_balancer_sku)
    error_message = "Load balancer SKU must be either 'basic' or 'standard'."
  }
}

variable "outbound_type" {
  description = "How outbound (egress) traffic from the cluster is routed. Use 'userAssignedNATGateway' when subnet_id points to a subnet with a NAT Gateway association (the default, created by the networking module). Use 'userDefinedRouting' when reusing an existing subnet that already has its own egress path (e.g. UDR to a firewall) instead of a NAT Gateway - the subnet_id subnet must NOT have a NAT Gateway associated in that case."
  type        = string
  default     = "userAssignedNATGateway"
  validation {
    condition     = contains(["loadBalancer", "managedNATGateway", "userAssignedNATGateway", "userDefinedRouting"], var.outbound_type)
    error_message = "outbound_type must be one of: loadBalancer, managedNATGateway, userAssignedNATGateway, userDefinedRouting."
  }
}

# ============================================================================
# API Server VNet Integration (Recommended for better performance)
# ============================================================================
# This enables API Server VNet Integration on Public Cluster Endpoint.
# Refer for more details: https://learn.microsoft.com/en-us/azure/aks/api-server-vnet-integration#deploy-a-public-cluster
variable "enable_api_server_vnet_integration" {
  description = "Enable API Server VNet Integration. Projects the API server into a delegated subnet in your VNet. Requires api_server_subnet_id to be provided."
  type        = bool
  default     = true
  nullable    = false
}

variable "api_server_subnet_id" {
  description = "Subnet ID for API Server VNet Integration (must be delegated to Microsoft.ContainerService/managedClusters). Required when enable_api_server_vnet_integration is true."
  type        = string
  default     = null

  validation {
    condition     = !var.enable_api_server_vnet_integration || var.api_server_subnet_id != null
    error_message = "api_server_subnet_id must be provided when enable_api_server_vnet_integration is true."
  }
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
