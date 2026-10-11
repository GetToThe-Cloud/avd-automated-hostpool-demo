#Requires -Version 7.2
<#
.SYNOPSIS
    Moves Pool B's session host configuration to another image version and starts (or schedules) the session host update.

.DESCRIPTION
    This is the slow part of the demo, so start it before you go on stage. AVD replaces the
    initial host first, then the rest in batches of maxVmsRemoved, at roughly 20 minutes per
    host. With two hosts and a batch size of 1 that is about 40 minutes in total; start it
    10 to 15 minutes before the demo and the Patch segment shows one host done and one in flight.

    The script refuses to run while a scaling plan is enabled on Pool B, because autoscale
    and session host update don't mix.

.EXAMPLE
    ./11-Start-PoolBUpdate.ps1                       # 1.0.0 -> 2.0.0, now

.EXAMPLE
    ./11-Start-PoolBUpdate.ps1 -StartAt '2026-11-12 18:50'   # scheduled, in your local time

.EXAMPLE
    ./11-Start-PoolBUpdate.ps1 -ImageVersion 1.0.0   # roll back for the next rehearsal
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive console script.')]
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('1.0.0', '2.0.0')]
    [string] $ImageVersion = '2.0.0',

    # Local time of this machine. Must be in the future and at most two weeks out.
    [datetime] $StartAt
)

$ErrorActionPreference = 'Stop'
Import-Module -Name (Join-Path $PSScriptRoot 'AvdDemo.psm1') -Force
$demo = Get-DemoEnvironment
$poolId = $demo.poolB.id

if ($PSBoundParameters.ContainsKey('StartAt') -and ($StartAt -le (Get-Date) -or $StartAt -gt (Get-Date).AddDays(14))) {
    throw 'StartAt must be in the future and at most two weeks from now.'
}

$current = Get-AvdSessionHostUpdateStatus -HostPoolId $poolId
if (Test-AvdUpdateRunning -Status $current) {
    throw "An update is already $($current.status). Watch it with ./22-Watch-PoolB.ps1 or cancel it in the portal first."
}

$enabledPlans = @(Invoke-AvdApi -Path "$poolId/scalingPlans" -All | Where-Object {
        $_.properties.hostPoolReferences | Where-Object { $_.hostPoolArmPath -eq $poolId -and $_.scalingPlanEnabled }
    })
if ($enabledPlans.Count) {
    throw "Autoscale is enabled on $($demo.poolB.name) through $($enabledPlans[0].name). Turn it off before a session host update."
}

$target = $demo.imageVersions | Where-Object { $_.name -eq $ImageVersion } | Select-Object -First 1
if (-not $target) { throw "Image version $ImageVersion isn't in the deployment outputs." }

$hosts = @(Get-AvdSessionHost -HostPoolId $poolId)
$management = Get-AvdSessionHostManagement -HostPoolId $poolId
$batch = [int]$management.properties.update.maxVmsRemoved
$batches = 1 + [math]::Ceiling([math]::Max($hosts.Count - 1, 0) / [math]::Max($batch, 1))

Write-DemoTitle -Text 'Pool B | Session host update' -Detail $demo.poolB.name
Write-DemoLine -Label 'New image' -Value "$ImageVersion (Marketplace build $($target.marketplaceVersion))"
Write-DemoLine -Label 'Hosts' -Value "$($hosts.Count), batch size ${batch}: initial host first, then $($batches - 1) more batch(es)"
Write-DemoLine -Label 'Expect' -Value "about $($batches * 20) minutes in total"
Write-DemoLine -Label 'Users' -Value "get '$($management.properties.update.logOffMessage)' and $($management.properties.update.logOffDelayMinutes) minute(s) to sign out"

if (-not $PSCmdlet.ShouldProcess($demo.poolB.name, "Update session hosts to image $ImageVersion")) { return }

Write-Host "`n  Switching the session host configuration to $ImageVersion (AVD validates it first)..."
$config = Set-AvdSessionHostImage -HostPoolId $poolId -ImageVersionId $target.id
Write-DemoLine -Label 'Configuration version' -Value (ConvertTo-AvdLocalTime -Timestamp $config.properties.version -TimeZoneId $demo.timeZone -Format 'yyyy-MM-dd HH:mm') -Color Cyan

$updateArgs = @{ HostPoolId = $poolId; TimeZoneId = $demo.timeZone }
if ($PSBoundParameters.ContainsKey('StartAt')) { $updateArgs.StartAt = $StartAt }
Start-AvdSessionHostUpdate @updateArgs

Start-Sleep -Seconds 15
$status = Get-AvdSessionHostUpdateStatus -HostPoolId $poolId
Write-DemoLine -Label 'Update status' -Value ([string]$status.status) -Color Green
if ($status.properties.scheduledDateTime) {
    Write-DemoLine -Label 'Scheduled for' -Value ((ConvertTo-AvdLocalTime -Timestamp $status.properties.scheduledDateTime -TimeZoneId $demo.timeZone -Format 'yyyy-MM-dd HH:mm') + " $($demo.timeZone). Check it matches what you meant.")
}
Write-Host "`n  Follow it with ./22-Watch-PoolB.ps1, or Session hosts in the portal (Current version vs Target version).`n"
