# terraform-azure-attachment-add-on

Attachment storage add-on for `azure-web-app`: a private Blob container (Entra ID auth only), Storage Blob Data Contributor for the app's managed identity, and the storage account name written to the app's Key Vault.

Input: `app_name` (must match the app). After writing the secret it refreshes the app's Key Vault references and restarts the app, so attachments turn on (and, on uninstall, off) without a manual step. Expect a short restart.
