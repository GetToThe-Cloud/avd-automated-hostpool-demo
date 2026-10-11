#Requires -Version 7.2
<#
.SYNOPSIS
    Live view for the Patch segment: Pool B's session host update, host by host.

.DESCRIPTION
    Shows the target configuration (the new image), the update status and progress, and for every
    host which configuration version and image it was built from, so you can point at the host
    that is already on this month's image and the one still waiting. Same host names before and
    after: the update replaces the VM, not the name.

.EXAMPLE
    ./22-Watch-PoolB.ps1
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Live console view for a presentation.')]
[CmdletBinding()]
param(
    [ValidateRange(5, 300)]
    [int] $RefreshSeconds = 20,

    # Draw once and exit.
    [switch] $Once
)

$ErrorActionPreference = 'Stop'
Import-Module -Name (Join-Path $PSScriptRoot 'AvdDemo.psm1') -Force
$demo = Get-DemoEnvironment
$poolId = $demo.poolB.id

function Format-Version([object] $Version) {
    ConvertTo-AvdLocalTime -Timestamp $Version -TimeZoneId $demo.timeZone -Format 'dd MMM HH:mm'
}

while ($true) {
    $target = Get-AvdSessionHostConfiguration -HostPoolId $poolId
    $active = Get-AvdSessionHostConfiguration -HostPoolId $poolId -Active
    $update = Get-AvdSessionHostUpdateStatus -HostPoolId $poolId
    $hosts = @(Get-AvdSessionHost -HostPoolId $poolId | Sort-Object -Property Name)

    $targetImage = Get-ImageVersionName -ImageVersionId $target.properties.imageInfo.customInfo.resourceId
    $activeImage = if ($active) { Get-ImageVersionName -ImageVersionId $active.properties.imageInfo.customInfo.resourceId } else { '' }

    if (-not $Once) { Clear-Host }
    Write-DemoTitle -Text 'Pool B | Session host update' -Detail "$($demo.poolB.name)   $((Get-AvdPlanTime -TimeZoneId $demo.timeZone).ToString('HH:mm')) $($demo.timeZone)"
    Write-DemoLine -Label 'Target' -Value "image $targetImage, configuration version $(Format-Version $target.properties.version)" -Color Cyan
    if ($active -and -not (Test-AvdSameTimestamp -First $active.properties.version -Second $target.properties.version)) {
        Write-DemoLine -Label 'Previous' -Value "image $activeImage, configuration version $(Format-Version $active.properties.version)"
    }

    if ($update) {
        $progress = $update.properties.progress
        $color = switch ($update.status) { 'Succeeded' { 'Green' } { $_ -in 'Failed', 'Error', 'Cancelled' } { 'Red' } default { 'Yellow' } }
        Write-DemoLine -Label 'Update' -Value ("{0}, {1}% complete" -f $update.status, [math]::Round([double]$update.percentComplete)) -Color $color
        if ($progress) {
            Write-DemoLine -Label 'Progress' -Value ('{0} of {1} hosts done, {2} in progress, started {3}' -f `
                    [int]$progress.sessionHostsCompleted, [int]$progress.totalSessionHosts, [int]$progress.sessionHostsInProgress, (ConvertTo-AvdLocalTime -Timestamp $progress.executionStartTime -TimeZoneId $demo.timeZone))
        }
        if ($update.error) {
            Write-DemoLine -Label 'Error' -Value "$($update.error.code): $($update.error.message)" -Color Red
        }
    }
    else {
        Write-DemoLine -Label 'Update' -Value 'none yet. Start one with ./11-Start-PoolBUpdate.ps1' -Color DarkGray
    }

    Write-Host ''
    $hosts | Select-Object -Property Name, Status,
        @{ Name = 'Drain'; Expression = { if ($_.AllowNewSession) { '' } else { 'drain' } } },
        Sessions,
        @{ Name = 'Built from'; Expression = {
                if (Test-AvdSameTimestamp -First $_.ConfigVersion -Second $target.properties.version) { "image $targetImage (target)" }
                elseif ($active -and (Test-AvdSameTimestamp -First $_.ConfigVersion -Second $active.properties.version)) { "image $activeImage" }
                elseif ($_.ConfigVersion) { "config $(Format-Version $_.ConfigVersion)" }
                else { '-' }
            }
        },
        @{ Name = 'Update state'; Expression = { $_.UpdateState } } |
        Format-Table -AutoSize | Out-String -Width 150 | Write-Host

    if ($Once) { break }
    Write-Host "  Refreshing every $RefreshSeconds s. Ctrl+C to stop. Each host takes about 20 minutes." -ForegroundColor DarkGray
    Start-Sleep -Seconds $RefreshSeconds
}
