output "storage_account_name" {
  description = "Storage account holding attachments."
  value       = azurerm_storage_account.attachments.name
}

output "container_name" {
  description = "Blob container for attachments."
  value       = azapi_resource.container.name
}
