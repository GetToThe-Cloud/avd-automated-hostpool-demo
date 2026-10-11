// Example parameters, for when you deploy without the scripts:
//
//   $env:AVD_DEMO_ADMIN_PASSWORD = '<a strong password>'
//   New-AzSubscriptionDeployment -Location westeurope -TemplateParameterFile ./main.bicepparam
//
// Run it twice: first with phase = 'foundation', then with phase = 'complete'.
// scripts/01-Deploy-Environment.ps1 does both runs and fills in the IDs and Marketplace builds for you.

using './main.bicep'

param prefix = 'avddemo'
param region = 'westeurope'
param phase = 'foundation' // then 'complete'
param timeZone = 'W. Europe Standard Time'

// (Get-AzADGroup -DisplayName 'AVD Demo Users').Id
param usersGroupObjectId = '00000000-0000-0000-0000-000000000000'

// (Get-AzADServicePrincipal -ApplicationId 9cdead84-a844-4324-93f2-b2e6bb768d07).Id
param avdServicePrincipalObjectId = '00000000-0000-0000-0000-000000000000'
param assignAvdServicePrincipalRoles = true

// Get-AzVMImage -Location westeurope -PublisherName MicrosoftWindowsDesktop -Offer windows-11 -Skus win11-25h2-avd
// Take the newest build for "latest" and the one before it for "previous".
param marketplaceSku = 'win11-25h2-avd'
param marketplaceVersionPrevious = '<second newest build>'
param marketplaceVersionLatest = '<newest build>'

param vmSize = 'Standard_D4ads_v5'
param intuneEnrollment = false
param vmAdminPassword = readEnvironmentVariable('AVD_DEMO_ADMIN_PASSWORD', '')

param poolAMaxSessionLimit = 2
param poolBHostCount = 2
param poolBBatchSize = 1
