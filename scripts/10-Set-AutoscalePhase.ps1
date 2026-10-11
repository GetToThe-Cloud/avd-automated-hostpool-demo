#Requires -Version 7.2
<#
.SYNOPSIS
    Puts Pool A's scaling plan in a given phase right now, by shifting the schedule times around the current time.

.DESCRIPTION
    Autoscale follows the clock, a presentation follows the agenda. This script moves the
    ramp-up, peak, ramp-down and off-peak start times so the plan is in the phase you need,
    whatever time it is. Changes to an assigned scaling plan apply immediately.

      RampUp    use before and during the demo. Scale-out works, scale-in doesn't happen in
                ramp-up, so a third host you just created stays put.
      RampDown  use for the scale-in step (23-Invoke-ScaleIn.ps1 does this for you).
      Default   restores the times and thresholds from the Bicep deployment.

.EXAMPLE
    ./10-Set-AutoscalePhase.ps1 -Phase RampUp

.EXAMPLE
    # Fallback trigger when the third user can't sign in: 2 sessions on 4 slots is 50%, above 40%.
    ./10-Set-AutoscalePhase.ps1 -Phase RampUp -RampUpCapacityThresholdPct 40
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive console script.')]
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateSet('RampUp', 'Peak', 'RampDown', 'OffPeak', 'Default')]
    [string] $Phase,

    [ValidateRange(1, 100)]
    [int] $RampUpCapacityThresholdPct
)

$ErrorActionPreference = 'Stop'
Import-Module -Name (Join-Path $PSScriptRoot 'AvdDemo.psm1') -Force
$demo = Get-DemoEnvironment

$phaseArgs = @{ Environment = $demo; Phase = $Phase }
if ($PSBoundParameters.ContainsKey('RampUpCapacityThresholdPct')) {
    $phaseArgs.RampUpCapacityThresholdPct = $RampUpCapacityThresholdPct
}
if (-not $PSCmdlet.ShouldProcess($demo.scalingPlan.name, "Move the schedule to $Phase")) { return }
$null = Set-AvdSchedulePhase @phaseArgs

$schedule = Get-AvdScalingSchedule -Environment $demo
$now = Get-AvdSchedulePhase -Schedule $schedule -TimeZoneId $demo.timeZone

Write-DemoTitle -Text 'Pool A scaling plan' -Detail $demo.scalingPlan.name
Write-DemoLine -Label 'Schedule' -Value $now.Times
Write-DemoLine -Label 'Phase now' -Value "$($now.Phase) at $($now.Now)" -Color Cyan
Write-DemoLine -Label 'Capacity threshold' -Value "$($now.CapacityThresholdPct)%"
Write-DemoLine -Label 'Host pool size' -Value "minimum $($now.MinHosts), maximum $($now.MaxHosts), $($now.MinimumActiveHostPct)% of the minimum stays running"

$expectation = switch ($now.Phase) {
    'RampUp' { "Autoscale tops the pool up to $($now.MinHosts) hosts and adds hosts above $($now.CapacityThresholdPct)% used capacity. No scale-in in this phase." }
    'Peak' { "Same threshold and sizes as ramp-up, but empty hosts can be removed again when capacity allows." }
    'RampDown' { "Empty hosts above the minimum of $($now.MinHosts) are deleted while used capacity stays under $($now.CapacityThresholdPct)%." }
    'OffPeak' { "Ramp-down threshold and sizes; autoscale waits for users to leave before it removes hosts." }
}
Write-DemoLine -Label 'What to expect' -Value $expectation -Color Yellow
Write-Host ''
