// AVD automated host pools demo
//
// Pool A ("scale") shows dynamic autoscaling: a scaling plan that creates and deletes
// session hosts from the session host configuration.
// Pool B ("patch") shows session host update: hosts move from image 1.0.0 to 2.0.0.
// Two pools because autoscale has to be off while a session host update runs.
//
// Deploy twice: phase 'foundation' first, then phase 'complete'. The first run creates the
// managed identities and their role assignments (and the images, which take a while), so the
// session host configurations in the second run find their permissions in place.
// scripts/01-Deploy-Environment.ps1 does both runs for you.

targetScope = 'subscription'

import { scalingScheduleSettings } from 'modules/types.bicep'

metadata name = 'AVD automated host pools demo'
metadata description = 'Two automated host pools: dynamic autoscaling on Pool A, session host update on Pool B.'

// ----- General -------------------------------------------------------------------------

@description('Short name used in every resource name. Lowercase letters and digits.')
@minLength(3)
@maxLength(8)
param prefix string = 'avddemo'

@description('Azure region for the AVD metadata and the session hosts.')
param region string = 'westeurope'

@description('foundation: everything except session host configurations, management policies and the scaling plan. complete: everything.')
@allowed([
  'foundation'
  'complete'
])
param phase string = 'complete'

@description('Windows time zone ID for the scaling plan and the management policies.')
param timeZone string = 'W. Europe Standard Time'

@description('Tags for every resource.')
param resourceTags object = {
  workload: 'avd-automated-hostpool-demo'
  'created-by': 'bicep'
}

// ----- Identities ----------------------------------------------------------------------

@description('Object ID of the Entra group with the demo users. Empty skips the desktop assignments.')
param usersGroupObjectId string = ''

@description('Object ID of the Azure Virtual Desktop service principal (app ID 9cdead84-a844-4324-93f2-b2e6bb768d07) in your tenant.')
param avdServicePrincipalObjectId string = ''

@description('Give the AVD service principal Power On Off Contributor and Virtual Machine Contributor on the subscription, as dynamic autoscaling requires. Set false if those assignments already exist.')
param assignAvdServicePrincipalRoles bool = true

// ----- Image ---------------------------------------------------------------------------

@description('Marketplace publisher of the source image.')
param marketplacePublisher string = 'MicrosoftWindowsDesktop'

@description('Marketplace offer of the source image.')
param marketplaceOffer string = 'windows-11'

@description('Marketplace SKU of the source image.')
param marketplaceSku string = 'win11-25h2-avd'

@description('Marketplace build that becomes gallery version 1.0.0 ("last month").')
param marketplaceVersionPrevious string

@description('Marketplace build that becomes gallery version 2.0.0 ("this month").')
param marketplaceVersionLatest string

// ----- Session hosts -------------------------------------------------------------------

@description('VM size for both pools.')
param vmSize string = 'Standard_D4ads_v5'

@description('OS disk type for both pools.')
param osDiskType 'Premium_LRS' | 'StandardSSD_LRS' | 'Standard_LRS' = 'Premium_LRS'

@description('Availability zones for the hosts. Empty means regional.')
param availabilityZones int[] = []

@description('Enroll the hosts in Intune. Needs automatic MDM enrollment set up in the tenant.')
param intuneEnrollment bool = false

@description('Local admin user name, stored in Key Vault.')
param vmAdminUsername string = 'avdadmin'

@description('Local admin password, stored in Key Vault. The deploy script generates one.')
@secure()
param vmAdminPassword string

@description('Custom RDP properties. enablerdsaadauth needs Entra authentication for RDP enabled in the tenant (00-Prerequisites.ps1 -EnableEntraSso).')
param rdpProperties string = 'enablerdsaadauth:i:1;targetisaadjoined:i:1'

// ----- Network -------------------------------------------------------------------------

@description('Address space for the demo virtual network.')
param vnetAddressPrefix string = '10.80.0.0/23'

@description('Session host subnet.')
param subnetAddressPrefix string = '10.80.0.0/24'

@description('Use an existing subnet instead of creating a network. The pool identities then also need subnet join rights on it.')
param existingSubnetId string = ''

@description('Key Vault firewall on with only trusted Microsoft services allowed.')
param keyVaultTrustedServicesOnly bool = false

// ----- Pool A: dynamic autoscaling -----------------------------------------------------

@description('Pool A max sessions per host. 2 makes the scale-out easy to trigger: 3 users on 2 hosts is 75%.')
@minValue(1)
param poolAMaxSessionLimit int = 2

@description('Gallery version Pool A builds hosts from.')
@allowed([
  '1.0.0'
  '2.0.0'
])
param poolAImageVersion string = '2.0.0'

@description('Dynamic autoscaling schedule for Pool A. The demo scripts shift the phase times around the moment you present.')
param scalingSchedule scalingScheduleSettings = {
  name: 'all-week'
  daysOfWeek: [
    'Monday'
    'Tuesday'
    'Wednesday'
    'Thursday'
    'Friday'
    'Saturday'
    'Sunday'
  ]
  rampUpStart: '07:00'
  peakStart: '09:00'
  rampDownStart: '17:00'
  offPeakStart: '20:00'
  rampUpMinHosts: 2
  rampUpMaxHosts: 4
  rampDownMinHosts: 1
  rampDownMaxHosts: 2
  rampUpCapacityThresholdPct: 60
  rampDownCapacityThresholdPct: 90
  minimumActiveHostsPct: 100 // only create and delete, never keep stopped hosts around
}

// ----- Pool B: session host update -----------------------------------------------------

@description('Pool B max sessions per host.')
@minValue(1)
param poolBMaxSessionLimit int = 4

@description('Gallery version in Pool B\'s session host configuration. Starts at 1.0.0; the demo updates it to 2.0.0.')
@allowed([
  '1.0.0'
  '2.0.0'
])
param poolBImageVersion string = '1.0.0'

@description('Number of hosts in Pool B.')
@minValue(1)
param poolBHostCount int = 2

@description('Pool B update batch size (maxVmsRemoved).')
@minValue(1)
param poolBBatchSize int = 1

// ----- Names ---------------------------------------------------------------------------

var names = {
  resourceGroup: 'rg-${prefix}'
  keyVault: 'kv-${prefix}-${take(uniqueString(subscription().id, prefix), 8)}'
  logAnalytics: 'log-${prefix}'
  workspace: 'vdws-${prefix}'
  poolA: 'vdpool-${prefix}-scale'
  poolB: 'vdpool-${prefix}-patch'
  appGroupA: 'vdag-${prefix}-scale'
  appGroupB: 'vdag-${prefix}-patch'
  scalingPlan: 'vdscaling-${prefix}'
}

var deployConfiguration = phase == 'complete'

var roleIds = {
  powerOnOffContributor: '40c5ff49-9181-41f8-ae61-143b0e78555e'
  virtualMachineContributor: 'a959dbd1-f747-45e3-8ba6-dd80f235f97c'
}

// ----- Resource group and shared resources ---------------------------------------------

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: names.resourceGroup
  location: region
  tags: resourceTags
}

module network 'modules/network.bicep' = if (empty(existingSubnetId)) {
  name: 'network'
  scope: rg
  params: {
    prefix: prefix
    location: region
    vnetAddressPrefix: vnetAddressPrefix
    subnetAddressPrefix: subnetAddressPrefix
    tags: resourceTags
  }
}

module keyVault 'modules/keyvault.bicep' = {
  name: 'keyvault'
  scope: rg
  params: {
    name: names.keyVault
    location: region
    adminUsername: vmAdminUsername
    adminPassword: vmAdminPassword
    trustedServicesOnly: keyVaultTrustedServicesOnly
    tags: resourceTags
  }
}

module monitoring 'modules/monitoring.bicep' = {
  name: 'monitoring'
  scope: rg
  params: {
    name: names.logAnalytics
    location: region
    tags: resourceTags
  }
}

module image 'modules/image.bicep' = {
  name: 'image'
  scope: rg
  params: {
    prefix: prefix
    location: region
    publisher: marketplacePublisher
    offer: marketplaceOffer
    sku: marketplaceSku
    versions: [
      {
        name: '1.0.0'
        marketplaceVersion: marketplaceVersionPrevious
      }
      {
        name: '2.0.0'
        marketplaceVersion: marketplaceVersionLatest
      }
    ]
    tags: resourceTags
  }
}

var subnetId = empty(existingSubnetId) ? network!.outputs.subnetId : existingSubnetId

// ----- AVD service principal: needed by dynamic autoscaling, on the subscription ---------

resource avdPowerOnOff 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (assignAvdServicePrincipalRoles && !empty(avdServicePrincipalObjectId)) {
  name: guid(subscription().id, avdServicePrincipalObjectId, roleIds.powerOnOffContributor)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleIds.powerOnOffContributor)
    principalId: avdServicePrincipalObjectId
    principalType: 'ServicePrincipal'
    description: 'Dynamic autoscaling: start and stop session hosts.'
  }
}

resource avdVmContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (assignAvdServicePrincipalRoles && !empty(avdServicePrincipalObjectId)) {
  name: guid(subscription().id, avdServicePrincipalObjectId, roleIds.virtualMachineContributor)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleIds.virtualMachineContributor)
    principalId: avdServicePrincipalObjectId
    principalType: 'ServicePrincipal'
    description: 'Dynamic autoscaling: create and delete session hosts.'
  }
}

// ----- Pool A: dynamic autoscaling -----------------------------------------------------

module poolA 'modules/hostpool.bicep' = {
  name: 'pool-a-scale'
  scope: rg
  params: {
    name: names.poolA
    location: region
    friendlyName: 'Pool A | Dynamic autoscaling'
    hostPoolDescription: 'Demo: dynamic autoscaling creates and deletes hosts from the session host configuration.'
    maxSessionLimit: poolAMaxSessionLimit
    rdpProperties: rdpProperties
    appGroupName: names.appGroupA
    usersGroupObjectId: usersGroupObjectId
    logAnalyticsWorkspaceId: monitoring.outputs.id
    keyVaultName: keyVault.outputs.name
    deployConfiguration: deployConfiguration
    sessionHost: {
      vmNamePrefix: 'vdscale'
      vmSize: vmSize
      osDiskType: osDiskType
      imageVersionId: '${image.outputs.definitionId}/versions/${poolAImageVersion}'
      subnetId: subnetId
      availabilityZones: availabilityZones
      intuneEnrollment: intuneEnrollment
      adminUsernameSecretUri: keyVault.outputs.credentialUris.username
      adminPasswordSecretUri: keyVault.outputs.credentialUris.password
      vmTags: union(resourceTags, { pool: 'A-scale' })
    }
    managementPolicy: {
      timeZone: timeZone
      maxVmsRemoved: 1
      logOffDelayMinutes: 5
      logOffMessage: 'This desktop is being updated. Save your work, you can reconnect straight away.'
      deleteOriginalVm: true
      setDrainMode: false
      failedSessionHostCleanupPolicy: 'KeepOne'
      canaryPolicy: 'Auto'
      // no instanceCount: the scaling plan owns the pool size
    }
    tags: resourceTags
  }
}

module scaling 'modules/scalingplan.bicep' = if (deployConfiguration) {
  name: 'scaling-plan'
  scope: rg
  params: {
    name: names.scalingPlan
    location: region
    timeZone: timeZone
    hostPoolId: poolA.outputs.id
    schedule: scalingSchedule
    tags: resourceTags
  }
  dependsOn: [
    avdPowerOnOff
    avdVmContributor
  ]
}

// ----- Pool B: session host update -----------------------------------------------------

module poolB 'modules/hostpool.bicep' = {
  name: 'pool-b-patch'
  scope: rg
  params: {
    name: names.poolB
    location: region
    friendlyName: 'Pool B | Session host update'
    hostPoolDescription: 'Demo: session host update replaces hosts in batches when the configuration changes.'
    maxSessionLimit: poolBMaxSessionLimit
    rdpProperties: rdpProperties
    appGroupName: names.appGroupB
    usersGroupObjectId: usersGroupObjectId
    logAnalyticsWorkspaceId: monitoring.outputs.id
    keyVaultName: keyVault.outputs.name
    deployConfiguration: deployConfiguration
    sessionHost: {
      vmNamePrefix: 'vdpatch'
      vmSize: vmSize
      osDiskType: osDiskType
      imageVersionId: '${image.outputs.definitionId}/versions/${poolBImageVersion}'
      subnetId: subnetId
      availabilityZones: availabilityZones
      intuneEnrollment: intuneEnrollment
      adminUsernameSecretUri: keyVault.outputs.credentialUris.username
      adminPasswordSecretUri: keyVault.outputs.credentialUris.password
      vmTags: union(resourceTags, { pool: 'B-patch' })
    }
    managementPolicy: {
      timeZone: timeZone
      maxVmsRemoved: poolBBatchSize
      logOffDelayMinutes: 2
      logOffMessage: 'This desktop moves to this month\'s image. Save your work, you can reconnect straight away.'
      deleteOriginalVm: true // as the docs recommend; false keeps the old VM and disk for you to clean up
      setDrainMode: false
      failedSessionHostCleanupPolicy: 'KeepOne'
      canaryPolicy: 'Auto'
      instanceCount: poolBHostCount // AVD creates the hosts, no registration token anywhere
    }
    tags: resourceTags
  }
}

// ----- Workspace -----------------------------------------------------------------------

module workspace 'modules/workspace.bicep' = {
  name: 'workspace'
  scope: rg
  params: {
    name: names.workspace
    location: region
    friendlyName: 'AVD automated host pools demo'
    appGroupIds: [
      poolA.outputs.appGroupId
      poolB.outputs.appGroupId
    ]
    logAnalyticsWorkspaceId: monitoring.outputs.id
    tags: resourceTags
  }
}

// ----- Outputs, read by the demo scripts ------------------------------------------------

output resourceGroupName string = rg.name
output region string = region
output timeZone string = timeZone
output keyVaultName string = keyVault.outputs.name

output poolA object = {
  name: poolA.outputs.name
  id: poolA.outputs.id
  appGroupId: poolA.outputs.appGroupId
  maxSessionLimit: poolAMaxSessionLimit
  imageVersion: poolAImageVersion
}

output poolB object = {
  name: poolB.outputs.name
  id: poolB.outputs.id
  appGroupId: poolB.outputs.appGroupId
  maxSessionLimit: poolBMaxSessionLimit
  imageVersion: poolBImageVersion
  hostCount: poolBHostCount
}

output scalingPlan object = {
  name: names.scalingPlan
  id: '${rg.id}/providers/Microsoft.DesktopVirtualization/scalingPlans/${names.scalingPlan}'
  scheduleName: scalingSchedule.name
  schedule: scalingSchedule
}

output workspace object = {
  name: names.workspace
  id: workspace.outputs.id
}

output imageVersions array = image.outputs.versions

output logAnalytics object = {
  id: monitoring.outputs.id
  customerId: monitoring.outputs.customerId
}
