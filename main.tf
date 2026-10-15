# Locate the application's resources from app_name (resource group is rg-<app_name>).
data "azurerm_resource_group" "app" {
  name = "rg-${var.app_name}"
}

data "azurerm_resources" "web_app" {
  resource_group_name = data.azurerm_resource_group.app.name
  type                = "Microsoft.Web/sites"
}

data "azurerm_resources" "key_vault" {
  resource_group_name = data.azurerm_resource_group.app.name
  type                = "Microsoft.KeyVault/vaults"
}

data "azurerm_linux_web_app" "app" {
  name                = data.azurerm_resources.web_app.resources[0].name
  resource_group_name = data.azurerm_resource_group.app.name
}

locals {
  key_vault_id = data.azurerm_resources.key_vault.resources[0].id
  short        = substr(replace(var.app_name, "-", ""), 0, 14)
}

resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

# Storage account (Entra ID auth only, no public blob access)
resource "azurerm_storage_account" "attachments" {
  name                            = "st${local.short}${random_string.suffix.result}"
  resource_group_name             = data.azurerm_resource_group.app.name
  location                        = data.azurerm_resource_group.app.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = false
  default_to_oauth_authentication = true
  tags = {
    app_name  = var.app_name
    ManagedBy = "terraform"
  }
}

# Created via ARM so no storage data-plane access is needed (shared keys are disabled).
resource "azapi_resource" "container" {
  type      = "Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01"
  name      = "attachments"
  parent_id = "${azurerm_storage_account.attachments.id}/blobServices/default"
  body = {
    properties = {
      publicAccess = "None"
    }
  }
}

# Let the web app's managed identity read/write blobs
resource "azurerm_role_assignment" "app_blob" {
  scope                = azurerm_storage_account.attachments.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azurerm_linux_web_app.app.identity[0].principal_id
  principal_type       = "ServicePrincipal"
}

# Publish the storage account name to the app's Key Vault secret (read by the app at startup).
resource "azapi_update_resource" "storage_account_secret" {
  type      = "Microsoft.KeyVault/vaults/secrets@2023-07-01"
  name      = "storage-account-name"
  parent_id = local.key_vault_id
  body = {
    properties = {
      value = azurerm_storage_account.attachments.name
    }
  }
  depends_on = [azurerm_role_assignment.app_blob, azapi_resource.container]
}

# On uninstall, reset the secret so the app disables attachments after its next restart.
resource "azapi_resource_action" "reset_secret" {
  type        = "Microsoft.KeyVault/vaults/secrets@2023-07-01"
  resource_id = "${local.key_vault_id}/secrets/storage-account-name"
  method      = "PUT"
  when        = "destroy"
  body = {
    properties = {
      value = "not-configured"
    }
  }
}
