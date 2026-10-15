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

# Storage account (private, no public blob access).
# Uses azurerm_storage_account so Infragraph links it to this workspace's state (MANAGES edge);
# azapi_resource-managed resources are not linked. The azurerm provider reads the account's
# data plane with shared keys after create, so shared key access must stay enabled.
# The app itself never uses keys: it authenticates with its managed identity (Entra ID).
resource "azurerm_storage_account" "attachments" {
  name                            = "st${local.short}${random_string.suffix.result}"
  resource_group_name             = data.azurerm_resource_group.app.name
  location                        = data.azurerm_resource_group.app.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false
  default_to_oauth_authentication = true
  tags = {
    app_name  = var.app_name
    ManagedBy = "terraform"
  }
}

# storage_account_id makes azurerm create the container through ARM (control plane).
resource "azurerm_storage_container" "attachments" {
  name                  = "attachments"
  storage_account_id    = azurerm_storage_account.attachments.id
  container_access_type = "private"
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
  depends_on = [azurerm_role_assignment.app_blob, azurerm_storage_container.attachments]
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
