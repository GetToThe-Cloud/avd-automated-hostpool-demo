#Requires -Version 7.2
<#
.SYNOPSIS
    Go/no-go check for the demo. Run it after deploying, again an hour before you present, and right before you go on.

.DESCRIPTION
    Checks the image versions, both session host configurations, the hosts in both pools, the
    scaling plan assignment and phase, the role assignments autoscale needs, the desktop
    assignments and whether autoscale diagnostics reach Log Analytics.

.EXAMPLE
    ./02-Test-Environment.ps1

.EXAMPLE
    ./02-Test-Environment.ps1 -AllowRunningUpdate   # after you started the Pool B update
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive console script.')]
[CmdletBinding()]
param(
    # Don't fail when a Pool B update is scheduled or running (expected just before the demo).
    [switch] $AllowRunningUpdate
)

$ErrorActionPreference = 'Stop'
Import-Module -Name (Join-Path $PSScriptRoot 'AvdDemo.psm1') -Force
$demo = Get-DemoEnvironment

$results = [System.Collections.Generic.List[object]]::new()
function Add-Result([string] $Check, [string] $Result, [string] $Detail) {
    $results.Add([pscustomobject]@{ Check = $Check; Result = $Result; Detail = $Detail })
    $color = switch ($Result) { 'OK' { 'Green' } 'WARN' { 'Yellow' } default { 'Red' } }
    Write-Host ('  [{0,-4}] {1}: {2}' -f $Result, $Check, $Detail) -ForegroundColor $color
}

Write-DemoTitle -Text 'Demo readiness' -Detail "$($demo.resourceGroupName), $(Get-AvdPlanTime -TimeZoneId $demo.timeZone | ForEach-Object { $_.ToString('ddd HH:mm') }) $($demo.timeZone)"

# --- Images ------------------------------------------------------------------------------
foreach ($version in $demo.imageVersions) {
    $image = Invoke-AvdApi -Path $version.id -ApiVersion '2024-03-03' -AllowNotFound
    $state = if ($image) { [string]$image.properties.provisioningState } else { 'missing' }
    $result = if ($state -eq 'Succeeded') { 'OK' } else { 'FAIL' }
    Add-Result -Check "Image $($version.name)" -Result $result -Detail "$state, Marketplace build $($version.marketplaceVersion)"
}

# --- Both pools: configuration and hosts --------------------------------------------------
$pools = @(
    @{ Label = 'Pool A'; Pool = $demo.poolA }
    @{ Label = 'Pool B'; Pool = $demo.poolB }
)
$hostsByPool = @{}
foreach ($entry in $pools) {
    $pool = $entry.Pool
    $config = Get-AvdSessionHostConfiguration -HostPoolId $pool.id
    if (-not $config) {
        Add-Result -Check "$($entry.Label) configuration" -Result 'FAIL' -Detail 'no session host configuration; did the complete phase run?'
        continue
    }
    $state = [string]$config.properties.provisioningState
    $image = Get-ImageVersionName -ImageVersionId $config.properties.imageInfo.customInfo.resourceId
    $result = if ($state -eq 'Succeeded') { 'OK' } else { 'FAIL' }
    $version = ConvertTo-AvdLocalTime -Timestamp $config.properties.version -TimeZoneId $demo.timeZone -Format 'yyyy-MM-dd HH:mm'
    Add-Result -Check "$($entry.Label) configuration" -Result $result -Detail "$state, image $image, version $version"

    $management = Get-AvdSessionHostManagement -HostPoolId $pool.id
    $result = if ($management) { 'OK' } else { 'FAIL' }
    $detail = if ($management) { "batch size $($management.properties.update.maxVmsRemoved), sign-out after $($management.properties.update.logOffDelayMinutes) min" } else { 'missing' }
    Add-Result -Check "$($entry.Label) management policy" -Result $result -Detail $detail

    $hosts = @(Get-AvdSessionHost -HostPoolId $pool.id)
    $hostsByPool[$entry.Label] = $hosts
    $available = @($hosts | Where-Object { $_.Status -eq 'Available' })
    $outdated = @($hosts | Where-Object { $_.ConfigVersion -and -not (Test-AvdSameTimestamp -First $_.ConfigVersion -Second $config.properties.version) })
    $detail = "$($available.Count) of $($hosts.Count) available"
    if ($outdated.Count) { $detail += ", $($outdated.Count) on an older configuration version" }
    $result = if ($hosts.Count -and $available.Count -eq $hosts.Count) { 'OK' } elseif ($hosts.Count) { 'WARN' } else { 'FAIL' }
    Add-Result -Check "$($entry.Label) hosts" -Result $result -Detail $detail
}

# --- Pool B specifics ----------------------------------------------------------------------
$hostsB = @($hostsByPool['Pool B'])
$result = if ($hostsB.Count -eq [int]$demo.poolB.hostCount) { 'OK' } else { 'WARN' }
Add-Result -Check 'Pool B size' -Result $result -Detail "$($hostsB.Count) hosts, expected $($demo.poolB.hostCount)"

$provisioning = Get-AvdProvisioningStatus -HostPoolId $demo.poolB.id
if ($provisioning) {
    $result = if ($provisioning.status -eq 'Succeeded') { 'OK' } elseif ($provisioning.status -in 'Failed', 'Canceled') { 'FAIL' } else { 'WARN' }
    Add-Result -Check 'Pool B provisioning' -Result $result -Detail "$($provisioning.status), $([math]::Round([double]$provisioning.percentComplete))% complete"
}

$update = Get-AvdSessionHostUpdateStatus -HostPoolId $demo.poolB.id
if (Test-AvdUpdateRunning -Status $update) {
    $result = if ($AllowRunningUpdate) { 'OK' } else { 'WARN' }
    Add-Result -Check 'Pool B update' -Result $result -Detail "$($update.status) (expected only once you started it for the demo)"
}
else {
    $last = if ($update) { "last update: $($update.status)" } else { 'no update has run yet' }
    Add-Result -Check 'Pool B update' -Result 'OK' -Detail "none running, $last"
}

$plansOnB = @(Invoke-AvdApi -Path "$($demo.poolB.id)/scalingPlans" -All)
if ($plansOnB.Count) {
    Add-Result -Check 'Pool B autoscale' -Result 'FAIL' -Detail 'a scaling plan is assigned; autoscale must be off while a session host update runs'
}
else {
    Add-Result -Check 'Pool B autoscale' -Result 'OK' -Detail 'no scaling plan, as intended'
}

# --- Pool A specifics ----------------------------------------------------------------------
$plan = Invoke-AvdApi -Path $demo.scalingPlan.id -AllowNotFound
if (-not $plan) {
    Add-Result -Check 'Scaling plan' -Result 'FAIL' -Detail 'missing'
}
else {
    $reference = @($plan.properties.hostPoolReferences | Where-Object { $_.hostPoolArmPath -eq $demo.poolA.id })
    $enabled = $reference.Count -and $reference[0].scalingPlanEnabled
    $result = if ($enabled) { 'OK' } else { 'FAIL' }
    $detail = if ($enabled) { "assigned to $($demo.poolA.name) and enabled" } else { "not enabled for $($demo.poolA.name)" }
    Add-Result -Check 'Scaling plan' -Result $result -Detail $detail

    $schedule = Get-AvdScalingSchedule -Environment $demo
    $phase = Get-AvdSchedulePhase -Schedule $schedule -TimeZoneId $demo.timeZone
    $result = if ($schedule.properties.scalingMethod -eq 'CreateDeletePowerManage') { 'OK' } else { 'FAIL' }
    Add-Result -Check 'Scaling method' -Result $result -Detail ([string]$schedule.properties.scalingMethod)
    $result = if ($phase.Phase -eq 'RampUp') { 'OK' } else { 'WARN' }
    Add-Result -Check 'Autoscale phase' -Result $result -Detail "$($phase.Phase) at $($phase.Now) ($($phase.Times)). Run ./10-Set-AutoscalePhase.ps1 -Phase RampUp before the demo"

    $hostsA = @($hostsByPool['Pool A'])
    $result = if ($hostsA.Count -ge [int]$phase.MinHosts) { 'OK' } else { 'WARN' }
    Add-Result -Check 'Pool A size' -Result $result -Detail "$($hostsA.Count) hosts, phase minimum $($phase.MinHosts), maximum $($phase.MaxHosts)"

    $sessions = @(Get-AvdUserSession -HostPoolId $demo.poolA.id)
    Add-Result -Check 'Pool A sessions' -Result 'OK' -Detail "$($sessions.Count) signed in. For the trigger: two before the demo, the third one live"
}

# --- Permissions and assignments ------------------------------------------------------------
$avdSp = Get-AzADServicePrincipal -ApplicationId '9cdead84-a844-4324-93f2-b2e6bb768d07'
$scope = "/subscriptions/$($demo.subscriptionId)"
foreach ($role in 'Desktop Virtualization Power On Off Contributor', 'Desktop Virtualization Virtual Machine Contributor') {
    $assignment = Get-AzRoleAssignment -ObjectId $avdSp.Id -RoleDefinitionName $role -Scope $scope -ErrorAction SilentlyContinue | Where-Object { $_.Scope -eq $scope }
    $result = if ($assignment) { 'OK' } else { 'FAIL' }
    Add-Result -Check "AVD SP: $role" -Result $result -Detail $(if ($assignment) { 'on the subscription' } else { 'missing on the subscription' })
}
foreach ($pool in $demo.poolA, $demo.poolB) {
    $users = @(Get-AzRoleAssignment -Scope $pool.appGroupId -RoleDefinitionName 'Desktop Virtualization User' -ErrorAction SilentlyContinue)
    $result = if ($users.Count) { 'OK' } else { 'WARN' }
    Add-Result -Check "Users on $(Get-ShortName $pool.appGroupId)" -Result $result -Detail "$($users.Count) assignment(s)"
}

# --- Diagnostics -----------------------------------------------------------------------------
$decisions = @(Get-AvdAutoscaleDecision -Environment $demo -HostPoolId $demo.poolA.id -Last 1 -LookbackMinutes 1440)
$result = if ($decisions.Count) { 'OK' } else { 'WARN' }
$detail = if ($decisions.Count) { "last evaluation $(ConvertTo-AvdLocalTime -Timestamp $decisions[0].TimeGenerated -TimeZoneId $demo.timeZone -Format 'ddd HH:mm')" } else { 'no WVDAutoscaleEvaluationPooled rows in the last 24 hours yet' }
Add-Result -Check 'Autoscale logs' -Result $result -Detail $detail

if ($demo.launchUrls) {
    Write-Host ''
    Write-DemoLine -Label 'Pool A launch URL' -Value $demo.launchUrls.poolA
    Write-DemoLine -Label 'Pool B launch URL' -Value $demo.launchUrls.poolB
}

# --- Verdict ----------------------------------------------------------------------------------
$failed = @($results | Where-Object { $_.Result -eq 'FAIL' })
$warnings = @($results | Where-Object { $_.Result -eq 'WARN' })
Write-Host ''
if ($failed.Count) {
    Write-Host "NO GO: $($failed.Count) failed, $($warnings.Count) warning(s)." -ForegroundColor Red
    exit 1
}
if ($warnings.Count) {
    Write-Host "GO with $($warnings.Count) warning(s). Read them once more." -ForegroundColor Yellow
}
else {
    Write-Host 'GO.' -ForegroundColor Green
}
