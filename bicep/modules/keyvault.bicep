// Key Vault with the local admin credentials the session host configurations point to.
// RBAC permission model: each host pool's managed identity gets Key Vault Secrets User
// in hostpool.bicep. Secrets are written through ARM, so the deploying account needs
// no data plane rights on the vault.

@description('Key Vault name, globally unique, 3 to 24 characters.')
@minLength(3)
@maxLength(24)
param name string

@description('Azure region.')
param location string

@description('Local admin user name for the session hosts.')
param adminUsername string

@description('Local admin password for the session hosts.')
@secure()
param adminPassword string

@description('Turn the Key Vault firewall on and only let trusted Microsoft services through. The AVD docs list this as the recommended setting; test host creation once after you switch it on.')
param trustedServicesOnly bool

@description('Tags for every resource.')
param tags object

resource vault 'Microsoft.KeyVault/vaults@2024-11-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    tenantId: tenant().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    enabledForTemplateDeployment: true // required by the session host configuration docs
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: trustedServicesOnly ? 'Deny' : 'Allow'
    }
  }
}

resource usernameSecret 'Microsoft.KeyVault/vaults/secrets@2024-11-01' = {
  parent: vault
  name: 'sessionhost-admin-username'
  properties: {
    value: adminUsername
    contentType: 'text/plain'
  }
}

resource passwordSecret 'Microsoft.KeyVault/vaults/secrets@2024-11-01' = {
  parent: vault
  name: 'sessionhost-admin-password'
  properties: {
    value: adminPassword
    contentType: 'text/plain'
  }
}

@description('Key Vault name.')
output name string = vault.name

@description('Key Vault resource ID.')
output id string = vault.id

// Versionless URIs on purpose. Every deployment writes a new secret version; pinning a
// version would change the session host configuration on every redeploy and mark all
// hosts as out of date.
@description('Secret URIs for the session host configuration.')
output credentialUris object = {
  username: usernameSecret.properties.secretUri
  password: passwordSecret.properties.secretUri
}
