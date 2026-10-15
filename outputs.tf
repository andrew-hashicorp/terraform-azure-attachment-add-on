output "storage_account_name" {
  description = "Storage account holding attachments."
  value       = azapi_resource.storage.name
}

output "container_name" {
  description = "Blob container for attachments."
  value       = azapi_resource.container.name
}
