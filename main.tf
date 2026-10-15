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

# Storage account (Entra ID auth only, no public blob access).
# Created via azapi: azurerm_storage_account polls the blob data plane with shared keys,
# which fails with KeyBasedAuthenticationNotPermitted when shared keys are disabled.
resource "azapi_resource" "storage" {
  type      = "Microsoft.Storage/storageAccounts@2023-05-01"
  name      = "st${local.short}${random_string.suffix.result}"
  parent_id = data.azurerm_resource_group.app.id
  location  = data.azurerm_resource_group.app.location
  tags = {
    app_name  = var.app_name
    ManagedBy = "terraform"
  }
  body = {
    kind = "StorageV2"
    sku  = { name = "Standard_LRS" }
    properties = {
      minimumTlsVersion            = "TLS1_2"
      allowBlobPublicAccess        = false
      allowSharedKeyAccess         = false
      defaultToOAuthAuthentication = true
      supportsHttpsTrafficOnly     = true
    }
  }
}

# Created via ARM so no storage data-plane access is needed (shared keys are disabled).
resource "azapi_resource" "container" {
  type      = "Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01"
  name      = "attachments"
  parent_id = "${azapi_resource.storage.id}/blobServices/default"
  body = {
    properties = {
      publicAccess = "None"
    }
  }
}

# Let the web app's managed identity read/write blobs
resource "azurerm_role_assignment" "app_blob" {
  scope                = azapi_resource.storage.id
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
      value = azapi_resource.storage.name
    }
  }
  depends_on = [azurerm_role_assignment.app_blob, azapi_resource.container]
}

# App Service caches Key Vault references and a restart alone does not re-read them.
# After the secret changes: refresh the references, then restart so the app sees the new value.
resource "azapi_resource_action" "refresh_references" {
  type        = "Microsoft.Web/sites@2022-03-01"
  resource_id = data.azurerm_linux_web_app.app.id
  action      = "config/configreferences/appsettings/refresh"
  method      = "POST"

  depends_on = [azapi_update_resource.storage_account_secret]
  lifecycle {
    replace_triggered_by = [azapi_update_resource.storage_account_secret]
  }
}

resource "azapi_resource_action" "restart" {
  type        = "Microsoft.Web/sites@2022-03-01"
  resource_id = data.azurerm_linux_web_app.app.id
  action      = "restart"
  method      = "POST"

  depends_on = [azapi_resource_action.refresh_references]
  lifecycle {
    replace_triggered_by = [azapi_resource_action.refresh_references]
  }
}

# ---------- Uninstall ----------
# Destroy runs in reverse dependency order: reset the secret, then refresh, then restart,
# so the app turns attachments off as soon as the add-on is removed.
resource "azapi_resource_action" "restart_on_destroy" {
  type        = "Microsoft.Web/sites@2022-03-01"
  resource_id = data.azurerm_linux_web_app.app.id
  action      = "restart"
  method      = "POST"
  when        = "destroy"
}

resource "azapi_resource_action" "refresh_on_destroy" {
  type        = "Microsoft.Web/sites@2022-03-01"
  resource_id = data.azurerm_linux_web_app.app.id
  action      = "config/configreferences/appsettings/refresh"
  method      = "POST"
  when        = "destroy"

  depends_on = [azapi_resource_action.restart_on_destroy]
}

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

  depends_on = [azapi_resource_action.refresh_on_destroy]
}
