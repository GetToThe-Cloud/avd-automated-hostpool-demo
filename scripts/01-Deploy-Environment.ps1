#Requires -Version 7.2
<#
.SYNOPSIS
    Deploys the demo environment: both automated host pools, the images, the scaling plan and everything around them.

.DESCRIPTION
    Runs bicep/main.bicep twice at subscription scope:
      1. phase 'foundation': network, Key Vault, Log Analytics, image versions 1.0.0 and 2.0.0,
         the host pools with their managed identities and role assignments.
      2. phase 'complete': session host configurations, management policies and the dynamic
         scaling plan. AVD then starts creating hosts on its own: Pool B through the management
         policy's instanceCount, Pool A through the scaling plan's minimum host pool size.
    The deployment outputs are saved to scripts/demo-environment.json for the other scripts.

    Safe to run again. On a rerun the script reuses the Marketplace builds the gallery versions
    were made from, so a new Patch Tuesday build doesn't try to change an existing image version.

.EXAMPLE
    ./01-Deploy-Environment.ps1 -SubscriptionId <id> -UsersGroupName 'AVD Demo Users'
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive console script.')]
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $SubscriptionId,

    [string] $Region = 'westeurope',

    [ValidatePattern('^[a-z0-9]{3,8}$')]
    [string] $Prefix = 'avddemo',

    # Display name of the Entra group with the demo users.
    [string] $UsersGroupName,

    # Or its object ID.
    [string] $UsersGroupObjectId,

    [string] $ImageSku = 'win11-25h2-avd',

    [string] $VmSize = 'Standard_D4ads_v5',

    [string] $TimeZone = 'W. Europe Standard Time',

    [switch] $IntuneEnrollment,

    # Local admin password for the hosts. A random one is generated when you leave it out;
    # it only lives in Key Vault, you sign in to the hosts with Entra ID.
    [securestring] $AdminPassword,

    # Keep the Bicep file in line with Pool B after the demo moved it to 2.0.0.
    [ValidateSet('1.0.0', '2.0.0')]
    [string] $PoolBImageVersion = '1.0.0',

    # Skip the foundation run, for quick reruns of the complete phase.
    [switch] $SkipFoundation
)

$ErrorActionPreference = 'Stop'
Import-Module -Name (Join-Path $PSScriptRoot 'AvdDemo.psm1') -Force
$templateFile = (Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '../bicep/main.bicep')).Path
$resourceGroupName = "rg-$Prefix"

function Get-DemoPassword {
    # Builds the SecureString one character at a time, so the password never exists as a plain string.
    $sets = 'ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnopqrstuvwxyz', '23456789', '!#%*-_=+'
    $all = -join $sets
    $chars = foreach ($set in $sets) { $set[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32($set.Length)] }
    $chars += 1..20 | ForEach-Object { $all[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32($all.Length)] }
    $secure = [securestring]::new()
    foreach ($char in ($chars | Sort-Object { [System.Security.Cryptography.RandomNumberGenerator]::GetInt32(1000) })) {
        $secure.AppendChar($char)
    }
    $secure.MakeReadOnly()
    $secure
}

# --- Context -----------------------------------------------------------------------------
if (-not (Get-AzContext)) { $null = Connect-AzAccount -Subscription $SubscriptionId }
$null = Set-AzContext -Subscription $SubscriptionId
Write-Host "`nDeploying the AVD automated host pool demo to $((Get-AzContext).Subscription.Name)`n" -ForegroundColor Cyan

# --- Demo users --------------------------------------------------------------------------
if (-not $UsersGroupObjectId -and $UsersGroupName) {
    $groups = @(Get-AzADGroup -DisplayName $UsersGroupName)
    if ($groups.Count -ne 1) { throw "Expected one group named '$UsersGroupName', found $($groups.Count)." }
    $UsersGroupObjectId = $groups[0].Id
}
if (-not $UsersGroupObjectId) {
    Write-Warning 'No users group given. The desktops get no assignments; add them later in the portal.'
}

# --- AVD service principal roles on the subscription (needed by dynamic autoscaling) ------
$avdSp = Get-AzADServicePrincipal -ApplicationId '9cdead84-a844-4324-93f2-b2e6bb768d07'
if (-not $avdSp) { throw 'Azure Virtual Desktop service principal not found. Run 00-Prerequisites.ps1 first.' }
$scope = "/subscriptions/$SubscriptionId"
$roles = 'Desktop Virtualization Power On Off Contributor', 'Desktop Virtualization Virtual Machine Contributor'
$missing = foreach ($role in $roles) {
    $assignment = Get-AzRoleAssignment -ObjectId $avdSp.Id -RoleDefinitionName $role -Scope $scope -ErrorAction SilentlyContinue |
        Where-Object { $_.Scope -eq $scope }
    if (-not $assignment) { $role }
}
$missing = @($missing)
# Let Bicep create both when neither exists. When one already exists, Bicep would hit
# RoleAssignmentExists, so create the other one here and keep Bicep out of it.
$assignInBicep = $missing.Count -eq $roles.Count
if (-not $assignInBicep) {
    foreach ($role in $missing) {
        Write-Host "  Assigning $role to the AVD service principal on the subscription"
        $null = New-AzRoleAssignment -ObjectId $avdSp.Id -RoleDefinitionName $role -Scope $scope
    }
}

# --- Marketplace builds for image 1.0.0 and 2.0.0 ----------------------------------------
$existing = @()
if (Get-AzResourceGroup -Name $resourceGroupName -ErrorAction SilentlyContinue) {
    $existing = @(Get-AzGalleryImageVersion -ResourceGroupName $resourceGroupName -GalleryName "gal_$Prefix" -GalleryImageDefinitionName 'win11-avd-multisession' -ErrorAction SilentlyContinue)
}
$v1 = $existing | Where-Object { $_.Name -eq '1.0.0' } | Select-Object -First 1
$v2 = $existing | Where-Object { $_.Name -eq '2.0.0' } | Select-Object -First 1
if ($v1 -and $v2 -and $v1.Tags['marketplaceVersion'] -and $v2.Tags['marketplaceVersion']) {
    $previousBuild = $v1.Tags['marketplaceVersion']
    $latestBuild = $v2.Tags['marketplaceVersion']
    Write-Host "  Reusing image builds: 1.0.0 = $previousBuild, 2.0.0 = $latestBuild"
}
else {
    $builds = @(Get-AzVMImage -Location $Region -PublisherName 'MicrosoftWindowsDesktop' -Offer 'windows-11' -Skus $ImageSku |
            Sort-Object -Property { [version]$_.Version } -Descending)
    if ($builds.Count -lt 2) { throw "Need at least two Marketplace builds of $ImageSku in $Region, found $($builds.Count)." }
    $latestBuild = $builds[0].Version
    $previousBuild = $builds[1].Version
    Write-Host "  Image 1.0.0 = $ImageSku build $previousBuild (last month)"
    Write-Host "  Image 2.0.0 = $ImageSku build $latestBuild (this month)"
}

if (-not $AdminPassword) { $AdminPassword = Get-DemoPassword }

# --- Deploy ------------------------------------------------------------------------------
$templateParameters = @{
    prefix                         = $Prefix
    region                         = $Region
    timeZone                       = $TimeZone
    usersGroupObjectId             = [string]$UsersGroupObjectId
    avdServicePrincipalObjectId    = $avdSp.Id
    assignAvdServicePrincipalRoles = $assignInBicep
    marketplaceSku                 = $ImageSku
    marketplaceVersionPrevious     = $previousBuild
    marketplaceVersionLatest       = $latestBuild
    vmSize                         = $VmSize
    intuneEnrollment               = [bool]$IntuneEnrollment
    vmAdminPassword                = $AdminPassword
    poolBImageVersion              = $PoolBImageVersion
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmm'
$phases = if ($SkipFoundation) { @('complete') } else { @('foundation', 'complete') }
foreach ($phase in $phases) {
    $note = if ($phase -eq 'foundation') { 'about 20 to 30 minutes on the first run, mostly gallery replication' } else { 'a few minutes' }
    Write-Host "`n  Phase '$phase' ($note)..." -ForegroundColor Cyan
    $deployment = @{
        Name         = "avd-demo-$phase-$stamp"
        Location     = $Region
        TemplateFile = $templateFile
        phase        = $phase
    } + $templateParameters
    $result = New-AzSubscriptionDeployment @deployment
    if ($result.ProvisioningState -ne 'Succeeded') {
        throw "Deployment $($deployment.Name) ended in state $($result.ProvisioningState)."
    }
    if ($phase -eq 'foundation') {
        Write-Host '  Giving the new role assignments a minute to propagate...'
        Start-Sleep -Seconds 60
    }
}

# --- Save the outputs for the other scripts ----------------------------------------------
$response = Invoke-AzRestMethod -Method GET -Path "/subscriptions/$SubscriptionId/providers/Microsoft.Resources/deployments/avd-demo-complete-${stamp}?api-version=2024-03-01"
$outputs = ($response.Content | ConvertFrom-Json -Depth 64).properties.outputs
$environment = [ordered]@{
    subscriptionId = $SubscriptionId
    deployedAt     = (Get-Date).ToUniversalTime().ToString('o')
}
foreach ($property in $outputs.PSObject.Properties) {
    $environment[$property.Name] = $property.Value.value
}

# --- Friendly desktop names in Windows App, and direct launch URLs for the demo users ------
$workspace = Invoke-AvdApi -Path $environment.workspace.id
$launchUrls = [ordered]@{}
foreach ($key in 'poolA', 'poolB') {
    $label = if ($key -eq 'poolA') { 'Pool A | Dynamic autoscaling' } else { 'Pool B | Session host update' }
    $desktop = Invoke-AvdApi -Path "$($environment[$key].appGroupId)/desktops/SessionDesktop" -Method PATCH -Body @{ properties = @{ friendlyName = $label } }
    $launchUrls[$key] = "https://windows.cloud.microsoft/webclient/avd/$($workspace.properties.objectId)/$($desktop.properties.objectId)"
}
$environment.launchUrls = $launchUrls
$environment | ConvertTo-Json -Depth 32 | Set-Content -Path (Get-DemoEnvironmentPath) -Encoding utf8
$demo = Get-DemoEnvironment

Write-Host "`nDone. Outputs saved to $(Get-DemoEnvironmentPath)." -ForegroundColor Green
Write-Host @"

AVD is now creating the session hosts on its own:
  Pool B ($($demo.poolB.name)): $($demo.poolB.hostCount) hosts from image $($demo.poolB.imageVersion), via the management policy.
  Pool A ($($demo.poolA.name)): the scaling plan's minimum for the current phase, from image $($demo.poolA.imageVersion).
Give it 20 to 30 minutes, then run ./02-Test-Environment.ps1.

Direct launch links for the demo users (add #loginHint=<upn> to skip the account picker):
  Pool A: $($demo.launchUrls.poolA)
  Pool B: $($demo.launchUrls.poolB)
"@
