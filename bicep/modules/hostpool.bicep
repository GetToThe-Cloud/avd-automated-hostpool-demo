// One automated host pool: the pool itself, its managed identity and roles, a desktop
// application group, diagnostics, and (in the complete phase) the session host
// configuration (WHAT) and the session host management policy (HOW).

import { sessionHostSettings, managementPolicySettings } from 'types.bicep'

@description('Host pool name.')
param name string

@description('Azure region for the host pool metadata and the session hosts.')
param location string

@description('Friendly name shown in the portal and on the application group.')
param friendlyName string

@description('Host pool description.')
param hostPoolDescription string

@description('Maximum sessions per host. Autoscale needs a real value here, not the default.')
@minValue(1)
param maxSessionLimit int

@description('Custom RDP properties.')
param rdpProperties string

@description('Name of the desktop application group.')
param appGroupName string

@description('Object ID of the Entra group that gets the desktop. Empty skips the assignment.')
param usersGroupObjectId string

@description('Log Analytics workspace resource ID for diagnostics.')
param logAnalyticsWorkspaceId string

@description('Name of the Key Vault with the local admin secrets.')
param keyVaultName string

@description('Create the session host configuration and management policy. False in the foundation phase, so role assignments can propagate first.')
param deployConfiguration bool

@description('What the session hosts look like.')
param sessionHost sessionHostSettings

@description('How hosts are created and updated.')
param managementPolicy managementPolicySettings

@description('Tags for the AVD resources.')
param tags object

var roleIds = {
  desktopVirtualizationVirtualMachineContributor: 'a959dbd1-f747-45e3-8ba6-dd80f235f97c'
  keyVaultSecretsUser: '4633458b-17de-408a-b874-0445c86b69e6'
  desktopVirtualizationUser: '1d18fff3-a72a-46b5-b4a9-0b38a3cd7e63'
}

var intuneMdmProviderGuid = '0000000a-0000-0000-c000-000000000000'

var diagnosticCategories = [
  'Checkpoint'
  'Error'
  'Management'
  'Connection'
  'HostRegistration'
  'AgentHealthStatus'
  'AutoscaleEvaluationPooled' // WVDAutoscaleEvaluationPooled
  'SessionHostManagement' // WVDSessionHostManagement
]

resource keyVault 'Microsoft.KeyVault/vaults@2024-11-01' existing = {
  name: keyVaultName
}

resource hostPool 'Microsoft.DesktopVirtualization/hostPools@2026-04-01-preview' = {
  name: name
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned' // does the create, update and delete work for this pool
  }
  properties: {
    friendlyName: friendlyName
    description: hostPoolDescription
    hostPoolType: 'Pooled' // automated pools are pooled only
    managementType: 'Automated' // decided at creation, can't be changed later
    loadBalancerType: 'BreadthFirst'
    maxSessionLimit: maxSessionLimit
    preferredAppGroupType: 'Desktop'
    customRdpProperty: rdpProperties
    validationEnvironment: false
    startVMOnConnect: false
  }
}

// The pool's identity creates the VMs in this resource group (subnet and gallery live here too).
resource vmContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, hostPool.id, roleIds.desktopVirtualizationVirtualMachineContributor)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleIds.desktopVirtualizationVirtualMachineContributor)
    principalId: hostPool.identity.principalId
    principalType: 'ServicePrincipal'
    description: 'Lets ${name} create, update and delete its session hosts.'
  }
}

// ... and reads the local admin credentials from Key Vault.
resource secretsUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, hostPool.id, roleIds.keyVaultSecretsUser)
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleIds.keyVaultSecretsUser)
    principalId: hostPool.identity.principalId
    principalType: 'ServicePrincipal'
    description: 'Lets ${name} read the session host admin credentials.'
  }
}

resource appGroup 'Microsoft.DesktopVirtualization/applicationGroups@2026-04-01-preview' = {
  name: appGroupName
  location: location
  tags: tags
  properties: {
    applicationGroupType: 'Desktop'
    hostPoolArmPath: hostPool.id
    friendlyName: friendlyName
  }
}

resource desktopUsers 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(usersGroupObjectId)) {
  name: guid(appGroup.id, usersGroupObjectId, roleIds.desktopVirtualizationUser)
  scope: appGroup
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleIds.desktopVirtualizationUser)
    principalId: usersGroupObjectId
    principalType: 'Group'
    description: 'Demo users get the ${friendlyName} desktop.'
  }
}
// No Virtual Machine User Login assignment: pools with a session host configuration don't need it.

resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-log-analytics'
  scope: hostPool
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      for category in diagnosticCategories: {
        category: category
        enabled: true
      }
    ]
  }
}

// WHAT every new host looks like.
resource configuration 'Microsoft.DesktopVirtualization/hostPools/sessionHostConfigurations@2026-04-01-preview' = if (deployConfiguration) {
  parent: hostPool
  name: 'default'
  properties: {
    friendlyName: 'Image ${last(split(sessionHost.imageVersionId, '/'))}'
    vmNamePrefix: sessionHost.vmNamePrefix
    vmSizeId: sessionHost.vmSize
    vmTags: sessionHost.vmTags
    availabilityZones: empty(sessionHost.availabilityZones) ? null : sessionHost.availabilityZones
    imageInfo: {
      type: 'Custom'
      customInfo: {
        resourceId: sessionHost.imageVersionId // gallery version, same subscription
      }
    }
    diskInfo: {
      managedDisk: {
        type: sessionHost.osDiskType
      }
    }
    domainInfo: sessionHost.intuneEnrollment
      ? {
          joinType: 'AzureActiveDirectory'
          azureActiveDirectoryInfo: {
            mdmProviderGuid: intuneMdmProviderGuid
          }
        }
      : {
          joinType: 'AzureActiveDirectory'
        }
    networkInfo: {
      subnetId: sessionHost.subnetId
    }
    securityInfo: {
      type: 'TrustedLaunch'
      secureBootEnabled: true
      vTpmEnabled: true
    }
    vmAdminCredentials: {
      usernameKeyVaultSecretUri: sessionHost.adminUsernameSecretUri
      passwordKeyVaultSecretUri: sessionHost.adminPasswordSecretUri
    }
    bootDiagnosticsInfo: {
      enabled: true // managed storage
    }
  }
  dependsOn: [
    vmContributor
    secretsUser
  ]
}

// HOW hosts are created and updated.
resource management 'Microsoft.DesktopVirtualization/hostPools/sessionHostManagements@2026-04-01-preview' = if (deployConfiguration) {
  parent: hostPool
  name: 'default'
  properties: {
    scheduledDateTimeZone: managementPolicy.timeZone
    update: {
      maxVmsRemoved: managementPolicy.maxVmsRemoved // batch size
      logOffDelayMinutes: managementPolicy.logOffDelayMinutes
      logOffMessage: managementPolicy.logOffMessage
      deleteOriginalVm: managementPolicy.deleteOriginalVm
    }
    provisioning: {
      // The pool size to reach. Omitted when autoscale owns the pool size.
      instanceCount: managementPolicy.?instanceCount
      setDrainMode: managementPolicy.setDrainMode
      canaryPolicy: managementPolicy.canaryPolicy
    }
    failedSessionHostCleanupPolicy: managementPolicy.failedSessionHostCleanupPolicy
  }
  dependsOn: [
    configuration
  ]
}

@description('Host pool resource ID.')
output id string = hostPool.id

@description('Host pool name.')
output name string = hostPool.name

@description('Desktop application group resource ID.')
output appGroupId string = appGroup.id

@description('Principal ID of the host pool managed identity.')
output principalId string = hostPool.identity.principalId
