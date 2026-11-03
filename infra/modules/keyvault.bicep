// Key Vault for one environment, using Azure RBAC (no access policies).
// Grants "Key Vault Secrets User" to the given principals (e.g. the web app and slot managed identities).

@description('Azure region for the resources.')
param location string

@description('Key Vault name (3-24 chars, globally unique).')
@minLength(3)
@maxLength(24)
param vaultName string

@description('Enable purge protection. Cannot be turned off once enabled, so keep it for long-lived environments.')
param enablePurgeProtection bool = false

@description('Days a deleted vault or secret is retained before it can be purged.')
@minValue(7)
@maxValue(90)
param softDeleteRetentionInDays int = 90

@description('Principal IDs (managed identities) that may read secrets.')
param secretReaderPrincipalIds array = []

param tags object = {}

// Built-in role: Key Vault Secrets User
var keyVaultSecretsUserRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')

resource vault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: vaultName
  location: location
  tags: tags
  properties: {
    tenantId: subscription().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: softDeleteRetentionInDays
    // Purge protection can only be set to true or omitted, never set back to false.
    enablePurgeProtection: enablePurgeProtection ? true : null
    publicNetworkAccess: 'Enabled'
  }
}

resource secretReaders 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for principalId in secretReaderPrincipalIds: {
  name: guid(vault.id, principalId, keyVaultSecretsUserRoleId)
  scope: vault
  properties: {
    roleDefinitionId: keyVaultSecretsUserRoleId
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}]

output vaultId string = vault.id
output vaultName string = vault.name
output vaultUri string = vault.properties.vaultUri
