#Requires -Version 7.2
<#
.SYNOPSIS
    One-time checks for the AVD automated host pool demo.

.DESCRIPTION
    Checks PowerShell modules and the Bicep CLI, registers the resource providers, checks that
    the region and VM size work for your subscription, compares the vCPU quota with what the
    demo needs, and looks up the Azure Virtual Desktop service principal.
    With -EnableEntraSso it also switches on Microsoft Entra authentication for RDP in your
    tenant, which the host pools' enablerdsaadauth:i:1 RDP property relies on.

.EXAMPLE
    ./00-Prerequisites.ps1 -SubscriptionId <id> -InstallMissingModules

.EXAMPLE
    ./00-Prerequisites.ps1 -SubscriptionId <id> -EnableEntraSso
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive console script.')]
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $SubscriptionId,

    [string] $Region = 'westeurope',

    [string] $VmSize = 'Standard_D4ads_v5',

    # Pool A can grow to 4 hosts, Pool B has 2.
    [ValidateRange(1, 100)]
    [int] $PlannedHosts = 6,

    [switch] $InstallMissingModules,

    [switch] $EnableEntraSso
)

$ErrorActionPreference = 'Stop'
$results = [System.Collections.Generic.List[object]]::new()
function Add-Result([string] $Check, [string] $Result, [string] $Detail) {
    $results.Add([pscustomobject]@{ Check = $Check; Result = $Result; Detail = $Detail })
    $color = switch ($Result) { 'OK' { 'Green' } 'WARN' { 'Yellow' } default { 'Red' } }
    Write-Host ('  [{0,-4}] {1}: {2}' -f $Result, $Check, $Detail) -ForegroundColor $color
}

Write-Host "`nAVD automated host pool demo: prerequisites`n" -ForegroundColor Cyan

# --- PowerShell modules and Bicep ------------------------------------------------------
$modules = @(
    @{ Name = 'Az.Accounts'; MinimumVersion = '3.0.0' }
    @{ Name = 'Az.Resources'; MinimumVersion = '7.0.0' }
    @{ Name = 'Az.Compute'; MinimumVersion = '8.0.0' }
    @{ Name = 'Az.OperationalInsights'; MinimumVersion = '3.2.0' }
)
foreach ($module in $modules) {
    $installed = Get-Module -ListAvailable -Name $module.Name | Sort-Object -Property Version -Descending | Select-Object -First 1
    if ($installed -and $installed.Version -ge [version]$module.MinimumVersion) {
        Add-Result -Check $module.Name -Result 'OK' -Detail "version $($installed.Version)"
        continue
    }
    if ($InstallMissingModules) {
        Install-Module -Name $module.Name -MinimumVersion $module.MinimumVersion -Scope CurrentUser -Repository PSGallery -Force -AllowClobber
        Add-Result -Check $module.Name -Result 'OK' -Detail 'installed'
    }
    else {
        Add-Result -Check $module.Name -Result 'FAIL' -Detail "needs $($module.MinimumVersion) or later; rerun with -InstallMissingModules"
    }
}
Write-Host '  (Az.DesktopVirtualization is optional: the scripts call the preview REST API directly.)' -ForegroundColor DarkGray

$bicep = Get-Command -Name bicep -ErrorAction SilentlyContinue
if ($bicep) {
    $bicepVersion = [regex]::Match((& $bicep.Source --version), '\d+\.\d+\.\d+').Value
    $result = if ([version]$bicepVersion -ge [version]'0.30.0') { 'OK' } else { 'WARN' }
    Add-Result -Check 'Bicep CLI' -Result $result -Detail "version $bicepVersion (0.30 or later recommended)"
}
else {
    Add-Result -Check 'Bicep CLI' -Result 'FAIL' -Detail 'not on PATH. Az PowerShell needs it to deploy .bicep files: https://aka.ms/bicep-install'
}

# --- Azure context -----------------------------------------------------------------------
if (-not (Get-AzContext)) {
    $null = Connect-AzAccount -Subscription $SubscriptionId
}
$context = Set-AzContext -Subscription $SubscriptionId
Add-Result -Check 'Subscription' -Result 'OK' -Detail "$($context.Subscription.Name) ($SubscriptionId)"

# --- Resource providers ------------------------------------------------------------------
$providers = 'Microsoft.DesktopVirtualization', 'Microsoft.Compute', 'Microsoft.Network', 'Microsoft.KeyVault', 'Microsoft.OperationalInsights', 'Microsoft.Insights'
foreach ($namespace in $providers) {
    $state = (Get-AzResourceProvider -ProviderNamespace $namespace | Select-Object -First 1).RegistrationState
    if ($state -ne 'Registered') {
        $null = Register-AzResourceProvider -ProviderNamespace $namespace
        $state = 'Registering'
    }
    Add-Result -Check "Provider $namespace" -Result 'OK' -Detail $state
}

# --- Region and VM size --------------------------------------------------------------------
$location = Get-AzLocation | Where-Object { $_.Location -eq $Region }
if (-not $location) { throw "Unknown region '$Region'." }
$hostPoolRegions = ((Get-AzResourceProvider -ProviderNamespace Microsoft.DesktopVirtualization).ResourceTypes |
    Where-Object { $_.ResourceTypeName -eq 'hostpools' }).Locations
if ($hostPoolRegions -contains $location.DisplayName) {
    Add-Result -Check 'AVD metadata region' -Result 'OK' -Detail $location.DisplayName
}
else {
    Add-Result -Check 'AVD metadata region' -Result 'FAIL' -Detail "$($location.DisplayName) can't hold host pools; pick another -Region"
}

$sku = Get-AzComputeResourceSku -Location $Region | Where-Object { $_.ResourceType -eq 'virtualMachines' -and $_.Name -eq $VmSize } | Select-Object -First 1
if (-not $sku) {
    Add-Result -Check 'VM size' -Result 'FAIL' -Detail "$VmSize doesn't exist in $Region"
}
else {
    $restricted = @($sku.Restrictions | Where-Object { $_.ReasonCode -eq 'NotAvailableForSubscription' -and $_.Type -eq 'Location' })
    if ($restricted.Count) {
        Add-Result -Check 'VM size' -Result 'FAIL' -Detail "$VmSize is restricted for this subscription in $Region"
    }
    else {
        Add-Result -Check 'VM size' -Result 'OK' -Detail "$VmSize ($($sku.Family))"
    }

    # --- Quota -------------------------------------------------------------------------------
    $vcpus = [int]($sku.Capabilities | Where-Object { $_.Name -eq 'vCPUs' }).Value
    $needed = $vcpus * $PlannedHosts
    $usage = Get-AzVMUsage -Location $Region
    foreach ($quotaName in @($sku.Family, 'cores')) {
        $quota = $usage | Where-Object { $_.Name.Value -eq $quotaName } | Select-Object -First 1
        if (-not $quota) { continue }
        $free = $quota.Limit - $quota.CurrentValue
        $label = if ($quotaName -eq 'cores') { 'Regional vCPU quota' } else { "$quotaName quota" }
        $result = if ($free -ge $needed) { 'OK' } else { 'FAIL' }
        Add-Result -Check $label -Result $result -Detail "$free of $($quota.Limit) free, demo needs $needed ($PlannedHosts x $vcpus vCPU)"
    }
}

# --- Azure Virtual Desktop service principal ------------------------------------------------
$avdAppId = '9cdead84-a844-4324-93f2-b2e6bb768d07'
$avdSp = Get-AzADServicePrincipal -ApplicationId $avdAppId
if (-not $avdSp) {
    Add-Result -Check 'AVD service principal' -Result 'FAIL' -Detail 'not found; it appears once Microsoft.DesktopVirtualization is registered'
}
else {
    Add-Result -Check 'AVD service principal' -Result 'OK' -Detail "$($avdSp.DisplayName), object ID $($avdSp.Id)"
    $scope = "/subscriptions/$SubscriptionId"
    foreach ($role in 'Desktop Virtualization Power On Off Contributor', 'Desktop Virtualization Virtual Machine Contributor') {
        $assigned = Get-AzRoleAssignment -ObjectId $avdSp.Id -RoleDefinitionName $role -Scope $scope -ErrorAction SilentlyContinue |
            Where-Object { $_.Scope -eq $scope }
        $detail = if ($assigned) { 'already assigned on the subscription' } else { '01-Deploy-Environment.ps1 assigns it' }
        Add-Result -Check $role -Result 'OK' -Detail $detail
    }
}

# --- Microsoft Entra authentication for RDP (single sign-on) ----------------------------------
$windowsCloudLoginAppId = '270efc09-cd0d-444b-a71f-39af4910ec45'
if ($EnableEntraSso) {
    foreach ($name in 'Microsoft.Graph.Authentication', 'Microsoft.Graph.Applications') {
        if (-not (Get-Module -ListAvailable -Name $name)) {
            if ($InstallMissingModules) { Install-Module -Name $name -Scope CurrentUser -Repository PSGallery -Force }
            else { throw "$name is needed for -EnableEntraSso. Rerun with -InstallMissingModules." }
        }
    }
    Import-Module Microsoft.Graph.Authentication, Microsoft.Graph.Applications
    Connect-MgGraph -Scopes 'Application.Read.All', 'Application-RemoteDesktopConfig.ReadWrite.All' -NoWelcome
    $wclSp = Get-MgServicePrincipal -Filter "AppId eq '$windowsCloudLoginAppId'"
    $config = Get-MgServicePrincipalRemoteDesktopSecurityConfiguration -ServicePrincipalId $wclSp.Id -ErrorAction SilentlyContinue
    if (-not ($config -and $config.IsRemoteDesktopProtocolEnabled)) {
        Update-MgServicePrincipalRemoteDesktopSecurityConfiguration -ServicePrincipalId $wclSp.Id -IsRemoteDesktopProtocolEnabled
        Add-Result -Check 'Entra auth for RDP' -Result 'OK' -Detail 'enabled on Windows Cloud Login'
    }
    else {
        Add-Result -Check 'Entra auth for RDP' -Result 'OK' -Detail 'already enabled on Windows Cloud Login'
    }
}
else {
    Add-Result -Check 'Entra auth for RDP' -Result 'WARN' -Detail 'not checked. The pools use enablerdsaadauth:i:1; rerun with -EnableEntraSso if SSO is not set up in this tenant yet'
}

# --- Summary -------------------------------------------------------------------------------
$failed = @($results | Where-Object { $_.Result -eq 'FAIL' })
Write-Host ''
if ($failed.Count) {
    Write-Host "$($failed.Count) check(s) failed. Fix them before you deploy." -ForegroundColor Red
    exit 1
}
Write-Host 'All set. Next: ./01-Deploy-Environment.ps1' -ForegroundColor Green
