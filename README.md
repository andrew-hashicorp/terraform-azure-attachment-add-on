# terraform-azure-attachment-add-on

Attachment storage add-on for `azure-web-app`: a private Blob container (Entra ID auth only), Storage Blob Data Contributor for the app's managed identity, and the storage account name written to the app's Key Vault.

Input: `app_name` (must match the app). Restart the web app afterwards so it picks up `AZURE_STORAGE_ACCOUNT`.
