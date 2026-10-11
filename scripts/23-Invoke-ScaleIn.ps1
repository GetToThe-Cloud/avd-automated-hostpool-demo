#Requires -Version 7.2
<#
.SYNOPSIS
    The Scale-in segment: the working day ends, users go home, autoscale deletes the hosts it no longer needs.

.DESCRIPTION
    Moves Pool A's schedule into ramp-down, tells the demo users goodbye and signs them out.
    With zero sessions, used capacity drops under the ramp-down threshold and autoscale deletes
    empty hosts down to the ramp-down minimum. Each sign-out is a session change, which triggers
    an autoscale evaluation straight away.

.EXAMPLE
    ./23-Invoke-ScaleIn.ps1

.EXAMPLE
    ./23-Invoke-ScaleIn.ps1 -KeepSessions   # only switch the phase, let users sign out themselves
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive console script.')]
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch] $KeepSessions,

    [ValidateRange(0, 120)]
    [int] $WarningSeconds = 15
)

$ErrorActionPreference = 'Stop'
Import-Module -Name (Join-Path $PSScriptRoot 'AvdDemo.psm1') -Force
$demo = Get-DemoEnvironment

if (-not $PSCmdlet.ShouldProcess($demo.poolA.name, 'Move to ramp-down and sign out all users')) { return }

$null = Set-AvdSchedulePhase -Environment $demo -Phase RampDown
$schedule = Get-AvdScalingSchedule -Environment $demo
$phase = Get-AvdSchedulePhase -Schedule $schedule -TimeZoneId $demo.timeZone
Write-DemoTitle -Text 'Pool A | Scale in' -Detail $demo.poolA.name
Write-DemoLine -Label 'Phase now' -Value "$($phase.Phase) at $($phase.Now)" -Color Cyan
Write-DemoLine -Label 'Rules' -Value "threshold $($phase.CapacityThresholdPct)%, keep at least $($phase.MinHosts) host(s)"

$sessions = @(Get-AvdUserSession -HostPoolId $demo.poolA.id)
if ($KeepSessions -or -not $sessions.Count) {
    Write-DemoLine -Label 'Sessions' -Value "$($sessions.Count) left as they are"
}
else {
    if ($WarningSeconds -gt 0) {
        $sessions | Send-AvdUserMessage -Title 'End of the demo day' -Message "Thanks for helping out. You'll be signed out in $WarningSeconds seconds."
        Write-DemoLine -Label 'Sessions' -Value "$($sessions.Count) warned, signing out in $WarningSeconds s..."
        Start-Sleep -Seconds $WarningSeconds
    }
    $sessions | Remove-AvdUserSession
    Write-DemoLine -Label 'Sessions' -Value "$($sessions.Count) signed out" -Color Green
}

$hosts = @(Get-AvdSessionHost -HostPoolId $demo.poolA.id)
$surplus = [math]::Max($hosts.Count - [int]$phase.MinHosts, 0)
Write-DemoLine -Label 'Expect' -Value "autoscale deletes $surplus empty host(s) over the next minutes; $($phase.MinHosts) stay" -Color Yellow
Write-Host "`n  Watch it with ./21-Watch-PoolA.ps1. Afterwards: ./30-Reset-Demo.ps1`n"
