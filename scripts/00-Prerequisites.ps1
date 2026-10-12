#Requires -Version 7.2
<#
.SYNOPSIS
    One-time checks for the AVD automated host pool demo.

.DESCRIPTION
    Checks PowerShell modules, Azure CLI and Bicep CLI, registers the resource providers,
    checks that the region and VM size work for your subscription, compares the vCPU quota
    with what the demo needs, and looks up the Azure Virtual Desktop service principal.
    With -EnableEntraSso it also switches on Microsoft Entra authentication for RDP in your
    tenant, which the host pools' enablerdsaadauth:i:1 RDP property relies on.

.EXAMPLE
    ./00-Prerequisites.ps1 -SubscriptionId <id> -InstallMissingPrerequisites

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

    [Alias('InstallMissingModules')]
    [switch] $InstallMissingPrerequisites,

    [switch] $EnableEntraSso
)

$ErrorActionPreference = 'Stop'
$results = [System.Collections.Generic.List[object]]::new()
Import-Module -Name (Join-Path $PSScriptRoot 'AvdDemo.psm1') -Force

function Add-Result([string] $Check, [string] $Result, [string] $Detail) {
    $results.Add([pscustomobject]@{ Check = $Check; Result = $Result; Detail = $Detail })
    $color = switch ($Result) { 'OK' { 'Green' } 'WARN' { 'Yellow' } default { 'Red' } }
    Write-Host ('  [{0,-4}] {1}: {2}' -f $Result, $Check, $Detail) -ForegroundColor $color
}

Write-Host "`nAVD automated host pool demo: prerequisites`n" -ForegroundColor Cyan

# --- Azure CLI -------------------------------------------------------------------------
function Get-AzureCliCommand {
    $command = Get-Command -Name az -ErrorAction SilentlyContinue
    if ($command) { return $command }

    $cliPaths = @()
    if ($env:ProgramFiles) {
        $cliPaths += Join-Path -Path $env:ProgramFiles -ChildPath 'Microsoft SDKs\Azure\CLI2\wbin\az.cmd'
    }
    if (${env:ProgramFiles(x86)}) {
        $cliPaths += Join-Path -Path ${env:ProgramFiles(x86)} -ChildPath 'Microsoft SDKs\Azure\CLI2\wbin\az.cmd'
    }
    foreach ($cliPath in $cliPaths) {
        if (Test-Path -Path $cliPath) {
            $env:Path = "$(Split-Path -Path $cliPath -Parent);$env:Path"
            return Get-Command -Name az -ErrorAction SilentlyContinue
        }
    }
    $null
}

$azureCli = Get-AzureCliCommand
if (-not $azureCli -and $InstallMissingPrerequisites) {
    $winget = Get-Command -Name winget -ErrorAction SilentlyContinue
    if (-not $winget) {
        Add-Result -Check 'Azure CLI' -Result 'FAIL' -Detail 'winget is not available; install from https://aka.ms/installazurecliwindows'
    }
    else {
        & $winget.Source install --exact --id Microsoft.AzureCLI
        if ($LASTEXITCODE -ne 0) {
            throw "winget failed to install Azure CLI (exit code $LASTEXITCODE). Install it from https://aka.ms/installazurecliwindows."
        }
        $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        $env:Path = (@($machinePath, $userPath) -join [System.IO.Path]::PathSeparator) + [System.IO.Path]::PathSeparator + $env:Path
        $azureCli = Get-AzureCliCommand
        if (-not $azureCli) {
            Add-Result -Check 'Azure CLI' -Result 'FAIL' -Detail 'installed, but not visible in this PowerShell session; close and reopen the terminal'
        }
    }
}
if ($azureCli) {
    Add-Result -Check 'Azure CLI' -Result 'OK' -Detail "available at $($azureCli.Source)"
}
elseif (-not ($results | Where-Object { $_.Check -eq 'Azure CLI' -and $_.Result -eq 'FAIL' })) {
    Add-Result -Check 'Azure CLI' -Result 'FAIL' -Detail 'not on PATH; rerun with -InstallMissingPrerequisites to install using winget'
}

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
    if ($InstallMissingPrerequisites) {
        Install-Module -Name $module.Name -MinimumVersion $module.MinimumVersion -Scope CurrentUser -Repository PSGallery -Force -AllowClobber
        Add-Result -Check $module.Name -Result 'OK' -Detail 'installed'
    }
    else {
        Add-Result -Check $module.Name -Result 'FAIL' -Detail "needs $($module.MinimumVersion) or later; rerun with -InstallMissingModules"
    }
}
Write-Host '  (Az.DesktopVirtualization is optional: the scripts call the preview REST API directly.)' -ForegroundColor DarkGray

$bicep = Get-Command -Name bicep -ErrorAction SilentlyContinue
if (-not $bicep -and $InstallMissingPrerequisites -and $azureCli) {
    & $azureCli.Source bicep install
    if ($LASTEXITCODE -ne 0) {
        throw "az bicep install failed (exit code $LASTEXITCODE). Install Bicep from https://aka.ms/bicep-install."
    }
    $bicepBin = Join-Path -Path $HOME -ChildPath '.azure\bin'
    if (Test-Path -Path (Join-Path -Path $bicepBin -ChildPath 'bicep.exe')) {
        $env:Path = "$bicepBin;$env:Path"
    }
    $bicep = Get-Command -Name bicep -ErrorAction SilentlyContinue
}
if ($bicep) {
    $bicepVersion = [regex]::Match((& $bicep.Source --version), '\d+\.\d+\.\d+').Value
    $result = if ([version]$bicepVersion -ge [version]'0.30.0') { 'OK' } else { 'WARN' }
    Add-Result -Check 'Bicep CLI' -Result $result -Detail "version $bicepVersion (0.30 or later recommended)"
}
else {
    Add-Result -Check 'Bicep CLI' -Result 'FAIL' -Detail 'not on PATH; rerun with -InstallMissingPrerequisites to install Azure CLI and run az bicep install'
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
$location = Get-AzLocation | Where-Object { $_.Location -eq $Region } | Select-Object -First 1
if (-not $location) { throw "Unknown region '$Region'." }

$requestedRegion = $Region
$deploymentTarget = Resolve-AvdDeploymentTarget -RequestedVmSize $VmSize -Region $Region
if ($deploymentTarget.IsRegionFallback) {
    $Region = $deploymentTarget.Region
    $location = Get-AzLocation | Where-Object { $_.Location -eq $Region } | Select-Object -First 1
    Add-Result -Check 'Deployment region' -Result 'WARN' -Detail "No compatible VM size in $requestedRegion; using $($location.DisplayName) instead"
}

$hostPoolRegions = ((Get-AzResourceProvider -ProviderNamespace Microsoft.DesktopVirtualization).ResourceTypes |
    Where-Object { $_.ResourceTypeName -eq 'hostpools' }).Locations
if ($hostPoolRegions -contains $location.DisplayName) {
    Add-Result -Check 'AVD metadata region' -Result 'OK' -Detail $location.DisplayName
}
else {
    Add-Result -Check 'AVD metadata region' -Result 'FAIL' -Detail "$($location.DisplayName) can't hold host pools; pick another -Region"
}

$vmSelection = $deploymentTarget.VmSizeSelection
$sku = $vmSelection.Sku
if (-not $sku) {
    Add-Result -Check 'VM size' -Result 'FAIL' -Detail $deploymentTarget.FailureReason
}
else {
    if ($vmSelection.IsFallback) {
        Add-Result -Check 'VM size' -Result 'WARN' -Detail "$VmSize isn't usable for this subscription; selected $($sku.Name) ($($sku.Family)) in $($location.DisplayName)"
    }
    else {
        Add-Result -Check 'VM size' -Result 'OK' -Detail "$($sku.Name) ($($sku.Family))"
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
    $loadedAuthentication = Get-Module -Name Microsoft.Graph.Authentication | Select-Object -First 1
    $availableApplications = @(Get-Module -ListAvailable -Name Microsoft.Graph.Applications)
    $availableAuthentication = @(Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)
    if ($loadedAuthentication) {
        $graphVersion = $loadedAuthentication.Version
    }
    else {
        $matchingVersions = @($availableApplications | Where-Object { $availableAuthentication.Version -contains $_.Version } |
            Sort-Object -Property Version -Descending)
        if ($matchingVersions.Count) {
            $graphVersion = $matchingVersions[0].Version
        }
        elseif ($availableApplications.Count) {
            $graphVersion = ($availableApplications | Sort-Object -Property Version -Descending | Select-Object -First 1).Version
        }
        else {
            Write-Host '  Installing Microsoft.Graph.Applications for -EnableEntraSso...'
            Install-Module -Name Microsoft.Graph.Applications -Scope CurrentUser -Repository PSGallery -Force
            $graphVersion = (Get-Module -ListAvailable -Name Microsoft.Graph.Applications |
                Sort-Object -Property Version -Descending | Select-Object -First 1).Version
        }
    }

    foreach ($name in 'Microsoft.Graph.Authentication', 'Microsoft.Graph.Applications') {
        $loadedModule = Get-Module -Name $name | Where-Object { $_.Version -eq $graphVersion } | Select-Object -First 1
        $availableModule = Get-Module -ListAvailable -Name $name | Where-Object { $_.Version -eq $graphVersion } | Select-Object -First 1
        $conflictingModule = Get-Module -Name $name | Where-Object { $_.Version -ne $graphVersion } | Select-Object -First 1
        if ($conflictingModule) {
            throw "$name version $($conflictingModule.Version) is already loaded, but version $graphVersion is required. Close and reopen PowerShell, then rerun this script."
        }
        if (-not $loadedModule -and -not $availableModule) {
            Write-Host "  Installing $name $graphVersion to match the loaded Graph SDK..."
            if ($name -eq 'Microsoft.Graph.Applications' -and $loadedAuthentication -and $loadedAuthentication.Version -eq $graphVersion) {
                $installCommand = Get-Command -Name Install-PSResource -ErrorAction SilentlyContinue
                if ($installCommand) {
                    Install-PSResource -Name $name -Version $graphVersion -Scope CurrentUser -Repository PSGallery -TrustRepository -SkipDependencyCheck -Quiet
                }
                else {
                    Install-Module -Name $name -RequiredVersion $graphVersion -Scope CurrentUser -Repository PSGallery -Force -SkipPublisherCheck -AllowClobber -ErrorAction Stop
                }
            }
            else {
                Install-Module -Name $name -RequiredVersion $graphVersion -Scope CurrentUser -Repository PSGallery -Force -ErrorAction Stop
            }
            $availableModule = Get-Module -ListAvailable -Name $name | Where-Object { $_.Version -eq $graphVersion } | Select-Object -First 1
            if (-not $availableModule) {
                throw "Failed to install $name version $graphVersion. Check the PowerShell Gallery connection and retry."
            }
        }
    }
    Import-Module Microsoft.Graph.Authentication -RequiredVersion $graphVersion
    Import-Module Microsoft.Graph.Applications -RequiredVersion $graphVersion
    try {
        Connect-MgGraph -Scopes 'Application.Read.All', 'Application-RemoteDesktopConfig.ReadWrite.All' -NoWelcome -ErrorAction Stop
    }
    catch {
        throw "Microsoft Graph sign-in failed or was canceled. Rerun with -EnableEntraSso and complete the browser sign-in. $($_.Exception.Message)"
    }
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
