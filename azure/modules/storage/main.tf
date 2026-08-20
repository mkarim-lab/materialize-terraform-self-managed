resource "azurerm_storage_account" "materialize" {
  name                = replace("${var.prefix}stg", "-", "")
  resource_group_name = var.resource_group_name
  location            = var.location
  # TODO: revisit to make sure we are using best set of values for storage account tier, replication type, and kind
  # and what other options user have to configure this.
  account_tier              = "Premium"
  account_replication_type  = "LRS"
  account_kind              = "BlockBlobStorage"
  min_tls_version           = "TLS1_2"
  shared_access_key_enabled = true

  public_network_access_enabled = var.public_network_access_enabled

  dynamic "network_rules" {
    for_each = length(var.subnets) == 0 ? [] : ["has_subnets"]
    content {
      default_action             = var.network_rules_default_action
      bypass                     = ["AzureServices"]
      virtual_network_subnet_ids = var.subnets
    }
  }

  tags = var.storage_account_tags

  lifecycle {
    # Microsoft Defender for Cloud's Storage Data Scanner attaches a
    # private_link_access block inside network_rules out-of-band. Terraform's
    # ignore_changes doesn't support indexing into a dynamically-generated
    # nested block's sub-attributes, so the whole network_rules block is
    # ignored here instead of having every plan/apply try to remove
    # Defender's own configuration. If you need to change
    # network_rules_default_action or subnets later, temporarily remove this
    # ignore_changes entry, apply, then re-add it.
    ignore_changes = [
      network_rules,
    ]
  }
}

resource "azurerm_storage_container" "materialize" {
  name                  = var.container_name
  storage_account_id    = azurerm_storage_account.materialize.id
  container_access_type = var.container_access_type
}

resource "random_string" "unique" {
  length  = 6
  special = false
  upper   = false
}

resource "azurerm_role_assignment" "storage_blob_contributor" {
  scope                = azurerm_storage_account.materialize.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = var.workload_identity_principal_id
}

# Federated identity credential that establishes trust between the Kubernetes service account
# and the Azure workload identity for storage access (similar to GCP Workload Identity or AWS IRSA)
resource "azurerm_federated_identity_credential" "materialize_storage" {
  name                = "${var.prefix}-storage-credential"
  resource_group_name = var.resource_group_name
  audience            = ["api://AzureADTokenExchange"]
  issuer              = var.oidc_issuer_url
  parent_id           = var.workload_identity_id
  subject             = "system:serviceaccount:${var.service_account_namespace}:${var.service_account_name}"
}

# Account SAS for persist blob access. Replaces workload-identity auth, which
# is unusable until mz_persist_client re-reads AZURE_FEDERATED_TOKEN_FILE.
data "azurerm_storage_account_sas" "persist" {
  connection_string = azurerm_storage_account.materialize.primary_connection_string
  https_only        = true
  signed_version    = "2022-11-02"

  resource_types {
    service   = true
    container = true
    object    = true
  }

  services {
    blob  = true
    queue = false
    table = false
    file  = false
  }

  # NOTE: hardcoded literals, deliberately. See gotcha #1 below.
  start  = "2026-08-01T00:00:00Z"
  expiry = "2029-08-01T00:00:00Z"

  permissions {
    read    = true
    write   = true
    delete  = true
    list    = true
    add     = true
    create  = true
    update  = true
    process = true
    tag     = false
    filter  = false
  }
}
