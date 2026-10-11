#Requires -Version 7.2
<#
.SYNOPSIS
    The "Define" segment: what, how and when for both pools, straight from the API.

.DESCRIPTION
    Prints the session host configuration (WHAT), the session host management policy (HOW)
    and the schedule (WHEN: the scaling plan for Pool A, session host update for Pool B).
    Handy as a fallback when the portal is slow on conference Wi-Fi.

.EXAMPLE
    ./20-Show-Configuration.ps1
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive console script.')]
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Import-Module -Name (Join-Path $PSScriptRoot 'AvdDemo.psm1') -Force
$demo = Get-DemoEnvironment

function Show-Pool([string] $Title, [object] $Pool) {
    $config = Get-AvdSessionHostConfiguration -HostPoolId $Pool.id
    $management = Get-AvdSessionHostManagement -HostPoolId $Pool.id
    $hostPool = Invoke-AvdApi -Path $Pool.id

    Write-DemoTitle -Text $Title -Detail "$($Pool.name), max $($hostPool.properties.maxSessionLimit) sessions per host"

    Write-Host '  WHAT  session host configuration' -ForegroundColor Cyan
    if ($config) {
        $c = $config.properties
        $imageName = Get-ImageVersionName -ImageVersionId $c.imageInfo.customInfo.resourceId
        $build = ($demo.imageVersions | Where-Object { $_.name -eq $imageName }).marketplaceVersion
        $join = if ($c.domainInfo.azureActiveDirectoryInfo.mdmProviderGuid) { 'Microsoft Entra ID + Intune' } else { 'Microsoft Entra ID' }
        Write-DemoLine -Label 'Image' -Value "gallery version $imageName (Marketplace build $build)"
        Write-DemoLine -Label 'Name prefix' -Value "$($c.vmNamePrefix)-0, $($c.vmNamePrefix)-1, ..."
        Write-DemoLine -Label 'Size and disk' -Value "$($c.vmSizeId), $($c.diskInfo.managedDisk.type)"
        Write-DemoLine -Label 'Security' -Value "$($c.securityInfo.type), secure boot $($c.securityInfo.secureBootEnabled), vTPM $($c.securityInfo.vTpmEnabled)"
        Write-DemoLine -Label 'Join' -Value $join
        Write-DemoLine -Label 'Subnet' -Value (($c.networkInfo.subnetId -split '/')[-3, -1] -join ' / ')
        Write-DemoLine -Label 'Admin credentials' -Value "Key Vault: $(($c.vmAdminCredentials.passwordKeyVaultSecretUri -split '/')[2])"
        Write-DemoLine -Label 'Version' -Value (ConvertTo-AvdLocalTime -Timestamp $c.version -TimeZoneId $demo.timeZone -Format 'yyyy-MM-dd HH:mm')
    }
    else {
        Write-DemoLine -Label 'Status' -Value 'not created yet' -Color Red
    }

    Write-Host '  HOW   session host management policy' -ForegroundColor Cyan
    if ($management) {
        $m = $management.properties
        $instances = if ($m.provisioning.instanceCount) { "$($m.provisioning.instanceCount) hosts" } else { 'left to autoscale' }
        Write-DemoLine -Label 'Pool size' -Value $instances
        Write-DemoLine -Label 'Batch size' -Value "$($m.update.maxVmsRemoved) host(s) at a time, initial host first"
        Write-DemoLine -Label 'Sign-out' -Value "after $($m.update.logOffDelayMinutes) min: '$($m.update.logOffMessage)'"
        Write-DemoLine -Label 'Original VM' -Value $(if ($m.update.deleteOriginalVm) { 'deleted after the update' } else { 'kept for rollback' })
        Write-DemoLine -Label 'New hosts' -Value "drain mode $($m.provisioning.setDrainMode), canary $($m.provisioning.canaryPolicy), failed hosts: $($m.failedSessionHostCleanupPolicy)"
        Write-DemoLine -Label 'Time zone' -Value $m.scheduledDateTimeZone
    }
    else {
        Write-DemoLine -Label 'Status' -Value 'not created yet' -Color Red
    }
}

Show-Pool -Title 'Pool A | Dynamic autoscaling' -Pool $demo.poolA

Write-Host '  WHEN  dynamic scaling plan' -ForegroundColor Cyan
$schedule = Get-AvdScalingSchedule -Environment $demo
$s = $schedule.properties
$phase = Get-AvdSchedulePhase -Schedule $schedule -TimeZoneId $demo.timeZone
Write-DemoLine -Label 'Method' -Value "$($s.scalingMethod) (creates and deletes hosts)"
Write-DemoLine -Label 'Ramp-up and peak' -Value "$($s.createDelete.rampUpMinimumHostPoolSize) to $($s.createDelete.rampUpMaximumHostPoolSize) hosts, threshold $($s.rampUpCapacityThresholdPct)%, $($s.rampUpMinimumHostsPct)% of minimum running"
Write-DemoLine -Label 'Ramp-down, off-peak' -Value "$($s.createDelete.rampDownMinimumHostPoolSize) to $($s.createDelete.rampDownMaximumHostPoolSize) hosts, threshold $($s.rampDownCapacityThresholdPct)%, $($s.rampDownMinimumHostsPct)% of minimum running"
Write-DemoLine -Label 'Load balancing' -Value "$($s.rampUpLoadBalancingAlgorithm) by day, $($s.offPeakLoadBalancingAlgorithm) at night"
Write-DemoLine -Label 'Schedule' -Value $phase.Times
Write-DemoLine -Label 'Phase now' -Value "$($phase.Phase) at $($phase.Now)" -Color Yellow

Show-Pool -Title 'Pool B | Session host update' -Pool $demo.poolB

Write-Host '  WHEN  session host update' -ForegroundColor Cyan
$update = Get-AvdSessionHostUpdateStatus -HostPoolId $demo.poolB.id
if ($update) {
    $when = if ($update.properties.scheduledDateTime) { ConvertTo-AvdLocalTime -Timestamp $update.properties.scheduledDateTime -TimeZoneId $demo.timeZone -Format 'yyyy-MM-dd HH:mm' } else { 'immediately' }
    Write-DemoLine -Label 'Latest update' -Value "$($update.status), scheduled $when" -Color Yellow
}
else {
    Write-DemoLine -Label 'Latest update' -Value 'none yet. Change the configuration, then schedule an update.' -Color Yellow
}
Write-Host ''
