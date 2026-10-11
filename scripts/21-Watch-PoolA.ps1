#Requires -Version 7.2
<#
.SYNOPSIS
    Live view for the Trigger, Harvest and Scale-in segments: Pool A's hosts, sessions and the capacity math autoscale uses.

.DESCRIPTION
    Shows the schedule phase, the used capacity (sessions divided by the slots on hosts that
    take new sessions), what autoscale should do about it, every host with its state, and the
    latest decisions from WVDAutoscaleEvaluationPooled with autoscale's own reason. The host and
    session data is live; Log Analytics usually trails by a few minutes.

.EXAMPLE
    ./21-Watch-PoolA.ps1

.EXAMPLE
    ./21-Watch-PoolA.ps1 -Once
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Live console view for a presentation.')]
[CmdletBinding()]
param(
    [ValidateRange(5, 300)]
    [int] $RefreshSeconds = 15,

    [ValidateRange(1, 20)]
    [int] $DecisionCount = 4,

    # Draw once and exit.
    [switch] $Once
)

$ErrorActionPreference = 'Stop'
Import-Module -Name (Join-Path $PSScriptRoot 'AvdDemo.psm1') -Force
$demo = Get-DemoEnvironment
$maxSessions = [int](Invoke-AvdApi -Path $demo.poolA.id).properties.maxSessionLimit
$decisions = @()
$decisionsFetched = [datetime]::MinValue

while ($true) {
    $schedule = Get-AvdScalingSchedule -Environment $demo
    $phase = Get-AvdSchedulePhase -Schedule $schedule -TimeZoneId $demo.timeZone
    $hosts = @(Get-AvdSessionHost -HostPoolId $demo.poolA.id | Sort-Object -Property Name)
    $sessions = @(Get-AvdUserSession -HostPoolId $demo.poolA.id)
    $capacity = Measure-AvdCapacity -SessionHost $hosts -MaxSessionLimit $maxSessions -CapacityThresholdPct $phase.CapacityThresholdPct -Phase $phase.Phase
    if (((Get-Date) - $decisionsFetched).TotalSeconds -ge 60) {
        $decisions = @(Get-AvdAutoscaleDecision -Environment $demo -HostPoolId $demo.poolA.id -Last $DecisionCount)
        $decisionsFetched = Get-Date
    }

    if (-not $Once) { Clear-Host }
    Write-DemoTitle -Text 'Pool A | Dynamic autoscaling' -Detail "$($demo.poolA.name)   $($phase.Now) $($demo.timeZone)"
    Write-DemoLine -Label 'Phase' -Value "$($phase.Phase)   ($($phase.Times))" -Color Cyan
    Write-DemoLine -Label 'Rules in this phase' -Value "threshold $($phase.CapacityThresholdPct)%, $($phase.MinHosts) to $($phase.MaxHosts) hosts, max $maxSessions sessions per host"
    $math = '{0} sessions / ({1} hosts x {2}) = {0}/{3} = {4}%' -f $capacity.Sessions, $capacity.ActiveHosts, $maxSessions, $capacity.Slots, $capacity.UsedPct
    $color = if ($capacity.UsedPct -gt $capacity.ThresholdPct) { 'Yellow' } else { 'Green' }
    Write-DemoLine -Label 'Used capacity' -Value $math -Color $color
    Write-DemoLine -Label 'Verdict' -Value "$($capacity.Verdict) (needs $($capacity.HostsNeeded) host(s) to stay under $($capacity.ThresholdPct)%)" -Color $color

    Write-Host ''
    if ($hosts.Count) {
        $hosts | Select-Object -Property Name, Status,
            @{ Name = 'Drain'; Expression = { if ($_.AllowNewSession) { '' } else { 'drain' } } },
            Sessions,
            @{ Name = 'Users'; Expression = { $name = $_.Name; ($sessions | Where-Object { $_.SessionHost -eq $name } | ForEach-Object { ($_.User -split '@')[0] }) -join ', ' } } |
            Format-Table -AutoSize | Out-String -Width 150 | Write-Host
    }
    else {
        Write-Host '  No session hosts yet. Autoscale creates them up to the phase minimum.' -ForegroundColor DarkGray
    }

    Write-Host '  Autoscale decisions (Log Analytics, a few minutes behind)' -ForegroundColor DarkGray
    if ($decisions.Count) {
        $decisions | Select-Object -Property @{ Name = 'Time'; Expression = { ConvertTo-AvdLocalTime -Timestamp $_.TimeGenerated -TimeZoneId $demo.timeZone } },
            Phase, Sessions, @{ Name = 'Hosts'; Expression = { '{0}/{1}' -f $_.ActiveHosts, $_.TotalHosts } },
            @{ Name = 'Used'; Expression = { "$($_.OccupancyPct)%" } },
            @{ Name = 'Reason'; Expression = { $text = [string]$_.Reason; if ($text.Length -gt 90) { $text.Substring(0, 87) + '...' } else { $text } } } |
            Format-Table -AutoSize -Wrap | Out-String -Width 160 | Write-Host
    }
    else {
        Write-Host '  (nothing yet)' -ForegroundColor DarkGray
    }

    if ($Once) { break }
    Write-Host "  Refreshing every $RefreshSeconds s. Ctrl+C to stop." -ForegroundColor DarkGray
    Start-Sleep -Seconds $RefreshSeconds
}
