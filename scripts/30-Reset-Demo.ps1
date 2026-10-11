#Requires -Version 7.2
<#
.SYNOPSIS
    Puts the environment back for the next rehearsal or the real thing.

.DESCRIPTION
    Restores the scaling plan schedule and thresholds from the Bicep deployment and makes sure
    autoscale is on for Pool A. With -RollbackPoolB it also moves Pool B back to image 1.0.0
    with another session host update, which takes about as long as the demo update did.

.EXAMPLE
    ./30-Reset-Demo.ps1

.EXAMPLE
    ./30-Reset-Demo.ps1 -RollbackPoolB
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive console script.')]
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch] $RollbackPoolB
)

$ErrorActionPreference = 'Stop'
Import-Module -Name (Join-Path $PSScriptRoot 'AvdDemo.psm1') -Force
$demo = Get-DemoEnvironment

if ($PSCmdlet.ShouldProcess($demo.scalingPlan.name, 'Restore the schedule and enable autoscale for Pool A')) {
    $null = Set-AvdSchedulePhase -Environment $demo -Phase Default
    $null = Set-AvdAutoscale -Environment $demo -Enabled $true
    $phase = Get-AvdSchedulePhase -Schedule (Get-AvdScalingSchedule -Environment $demo) -TimeZoneId $demo.timeZone
    Write-DemoTitle -Text 'Reset' -Detail $demo.resourceGroupName
    Write-DemoLine -Label 'Pool A schedule' -Value $phase.Times
    Write-DemoLine -Label 'Phase now' -Value "$($phase.Phase), $($phase.MinHosts) to $($phase.MaxHosts) hosts"
}

if ($RollbackPoolB) {
    & (Join-Path $PSScriptRoot '11-Start-PoolBUpdate.ps1') -ImageVersion '1.0.0'
}
else {
    $config = Get-AvdSessionHostConfiguration -HostPoolId $demo.poolB.id
    $image = Get-ImageVersionName -ImageVersionId $config.properties.imageInfo.customInfo.resourceId
    Write-DemoLine -Label 'Pool B image' -Value "$image. Use -RollbackPoolB to go back to 1.0.0 for another run."
    if ($image -ne $demo.poolB.imageVersion) {
        Write-DemoLine -Label 'Note' -Value "Bicep still says $($demo.poolB.imageVersion). Redeploy with -PoolBImageVersion $image to keep it in line." -Color Yellow
    }
}
Write-Host ''
