#Requires -Version 7.2
<#
    Helper functions for the AVD automated host pool demo.

    Everything that touches session host configuration, session host management, session
    host update or dynamic autoscaling goes straight to the ARM REST API with
    Invoke-AzRestMethod and the preview api-version. That needs only Az.Accounts, avoids
    installing the preview Az.DesktopVirtualization module next to the GA one on a
    presenter laptop, and shows exactly what the portal does under the hood.
    The equivalent preview cmdlet is named in the help of each function.
#>

$script:ApiVersion = '2026-04-01-preview'
$script:EnvironmentFile = Join-Path -Path $PSScriptRoot -ChildPath 'demo-environment.json'
# PowerShell 7.5 can keep ISO dates as strings; older versions turn them into DateTime.
$script:JsonDateArgs = if ((Get-Command -Name ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { @{ DateKind = 'String' } } else { @{} }
$script:UpdateRunningStates = @('Scheduled', 'ValidatingSessionHostUpdate', 'UpdatingSessionHosts', 'Pausing', 'Paused', 'Cancelling')

#region Plumbing

function Resolve-AvdVmSize {
    <#
    .SYNOPSIS
    Uses the requested VM size when it is available, otherwise selects a compatible size.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $RequestedVmSize,
        [Parameter(Mandatory)] [string] $Region
    )

    $vmSkus = @(Get-AzComputeResourceSku -Location $Region | Where-Object { $_.ResourceType -eq 'virtualMachines' })
    $requestedSku = $vmSkus | Where-Object { $_.Name -eq $RequestedVmSize } | Select-Object -First 1
    if (-not $requestedSku) {
        return [pscustomobject]@{
            Sku           = $null
            IsFallback    = $false
            FailureReason = "$RequestedVmSize isn't available in $Region, so its required size can't be determined."
        }
    }

    $requestedCapabilities = @{}
    foreach ($capability in $requestedSku.Capabilities) {
        $requestedCapabilities[$capability.Name] = $capability.Value
    }
    if (-not $requestedCapabilities['vCPUs'] -or -not $requestedCapabilities['MemoryGB']) {
        return [pscustomobject]@{
            Sku           = $null
            IsFallback    = $false
            FailureReason = "Azure didn't return vCPU and memory details for $RequestedVmSize."
        }
    }

    $requiredVcpus = [int]$requestedCapabilities['vCPUs']
    $requiredMemory = [decimal]$requestedCapabilities['MemoryGB']
    $eligibleSkus = foreach ($candidate in $vmSkus) {
        $restricted = @($candidate.Restrictions | Where-Object {
            $_.ReasonCode -eq 'NotAvailableForSubscription' -and $_.Type -eq 'Location'
        })
        if ($restricted.Count) { continue }

        $capabilities = @{}
        foreach ($capability in $candidate.Capabilities) {
            $capabilities[$capability.Name] = $capability.Value
        }
        if (-not $capabilities['vCPUs'] -or -not $capabilities['MemoryGB']) { continue }
        if ([int]$capabilities['vCPUs'] -ne $requiredVcpus) { continue }
        if ([decimal]$capabilities['MemoryGB'] -ne $requiredMemory) { continue }
        if ($capabilities['PremiumIO'] -ne 'True') { continue }
        if (($capabilities['HyperVGenerations'] -split ',') -notcontains 'V2') { continue }
        if ($capabilities['TrustedLaunchDisabled'] -eq 'True') { continue }
        if ($capabilities['TrustedLaunchSupported'] -eq 'False') { continue }
        if ($capabilities['CpuArchitectureType'] -and $capabilities['CpuArchitectureType'] -ne 'x64') { continue }

        $candidate
    }

    $selectedSku = $eligibleSkus | Where-Object { $_.Name -eq $RequestedVmSize } | Select-Object -First 1
    if (-not $selectedSku) {
        $selectedSku = $eligibleSkus |
            Sort-Object -Property @{
                Expression = {
                    if ($_.Name -like 'Standard_D*_v5') { 0 }
                    elseif ($_.Name -like 'Standard_D*') { 1 }
                    else { 2 }
                }
            }, Name |
            Select-Object -First 1
    }

    if (-not $selectedSku) {
        return [pscustomobject]@{
            Sku           = $null
            IsFallback    = $false
            FailureReason = "No unrestricted $requiredVcpus-vCPU, $requiredMemory-GB VM size in $Region supports Gen2, Trusted Launch, and Premium Storage."
        }
    }

    [pscustomobject]@{
        Sku           = $selectedSku
        IsFallback    = $selectedSku.Name -ne $RequestedVmSize
        FailureReason = $null
    }
}

function Resolve-AvdDeploymentTarget {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $RequestedVmSize,
        [Parameter(Mandatory)] [string] $Region
    )

    $location = Get-AzLocation | Where-Object { $_.Location -eq $Region } | Select-Object -First 1
    if (-not $location) {
        return [pscustomobject]@{
            Region             = $Region
            VmSizeSelection    = $null
            IsRegionFallback   = $false
            FailureReason      = "Unknown Azure region '$Region'."
        }
    }

    $selection = Resolve-AvdVmSize -RequestedVmSize $RequestedVmSize -Region $Region
    if ($selection.Sku -or $Region -ine 'uksouth') {
        return [pscustomobject]@{
            Region           = $Region
            VmSizeSelection  = $selection
            IsRegionFallback = $false
            FailureReason    = $selection.FailureReason
        }
    }

    $fallbackRegion = 'westeurope'
    $fallbackLocation = Get-AzLocation | Where-Object { $_.Location -eq $fallbackRegion } | Select-Object -First 1
    if (-not $fallbackLocation) {
        return [pscustomobject]@{
            Region           = $Region
            VmSizeSelection  = $null
            IsRegionFallback = $false
            FailureReason    = "$($selection.FailureReason) The West Europe fallback region is not available to this subscription."
        }
    }

    $hostPoolRegions = (Get-AzResourceProvider -ProviderNamespace Microsoft.DesktopVirtualization).ResourceTypes |
        Where-Object { $_.ResourceTypeName -eq 'hostpools' } |
        Select-Object -ExpandProperty Locations
    if ($hostPoolRegions -notcontains $fallbackLocation.DisplayName) {
        return [pscustomobject]@{
            Region           = $Region
            VmSizeSelection  = $null
            IsRegionFallback = $false
            FailureReason    = "$($selection.FailureReason) AVD host pools are not supported in West Europe for this subscription."
        }
    }

    $fallbackSelection = Resolve-AvdVmSize -RequestedVmSize $RequestedVmSize -Region $fallbackRegion
    if (-not $fallbackSelection.Sku) {
        return [pscustomobject]@{
            Region           = $Region
            VmSizeSelection  = $null
            IsRegionFallback = $false
            FailureReason    = "$($selection.FailureReason) West Europe also has no compatible VM size: $($fallbackSelection.FailureReason)"
        }
    }

    [pscustomobject]@{
        Region           = $fallbackRegion
        VmSizeSelection  = $fallbackSelection
        IsRegionFallback = $true
        FailureReason    = $null
    }
}

function Get-DemoEnvironmentPath {
    <#
    .SYNOPSIS
    Returns the path of the file that holds the deployment outputs.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $script:EnvironmentFile
}

function Get-DemoEnvironment {
    <#
    .SYNOPSIS
    Reads the deployment outputs written by 01-Deploy-Environment.ps1 and selects the right subscription.
    #>
    [CmdletBinding()]
    param(
        # Skip checking and switching the Az context.
        [switch] $SkipContext
    )

    if (-not (Test-Path -Path $script:EnvironmentFile)) {
        throw "No $script:EnvironmentFile found. Run 01-Deploy-Environment.ps1 first."
    }
    $environment = Get-Content -Path $script:EnvironmentFile -Raw | ConvertFrom-Json -Depth 32

    if (-not $SkipContext) {
        $context = Get-AzContext
        if (-not $context) {
            throw 'Not signed in to Azure. Run Connect-AzAccount first.'
        }
        if ($context.Subscription.Id -ne $environment.subscriptionId) {
            $null = Set-AzContext -Subscription $environment.subscriptionId
        }
    }
    $environment
}

function Assert-AvdResponse {
    <#
    .SYNOPSIS
    Throws a readable error when an ARM call fails.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Response,
        [Parameter(Mandatory)] [string] $Description
    )

    if ($Response.StatusCode -lt 400) {
        return
    }
    $detail = $Response.Content
    try {
        $body = $Response.Content | ConvertFrom-Json -Depth 32
        if ($body.error) {
            $detail = '{0}: {1}' -f $body.error.code, $body.error.message
        }
    }
    catch {
        Write-Verbose -Message 'Error body was not JSON.'
    }
    throw "$Description failed with HTTP $($Response.StatusCode). $detail"
}

function Invoke-AvdApi {
    <#
    .SYNOPSIS
    Calls the ARM REST API with the preview api-version and returns the parsed JSON.
    .PARAMETER Path
    ARM path without api-version, for example /subscriptions/.../hostPools/x/sessionHosts.
    .PARAMETER All
    Follow nextLink and return every item of a list.
    .PARAMETER AllowNotFound
    Return $null instead of throwing on HTTP 404.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [ValidateSet('GET', 'PUT', 'PATCH', 'POST', 'DELETE')] [string] $Method = 'GET',
        [object] $Body,
        [string] $ApiVersion = $script:ApiVersion,
        [switch] $All,
        [switch] $AllowNotFound
    )

    $separator = if ($Path.Contains('?')) { '&' } else { '?' }
    $request = @{
        Path   = "$Path${separator}api-version=$ApiVersion"
        Method = $Method
    }
    if ($PSBoundParameters.ContainsKey('Body')) {
        $request.Payload = ConvertTo-Json -InputObject $Body -Depth 20 -Compress
    }

    $response = Invoke-AzRestMethod @request
    if ($AllowNotFound -and $response.StatusCode -eq 404) {
        return $null
    }
    Assert-AvdResponse -Response $response -Description "$Method $Path"
    if ([string]::IsNullOrWhiteSpace($response.Content)) {
        return $null
    }
    $result = $response.Content | ConvertFrom-Json -Depth 64 @script:JsonDateArgs
    if (-not $All) {
        return $result
    }

    $items = [System.Collections.Generic.List[object]]::new()
    while ($true) {
        foreach ($item in @($result.value)) {
            if ($null -ne $item) { $items.Add($item) }
        }
        if (-not $result.nextLink) { break }
        $response = Invoke-AzRestMethod -Uri $result.nextLink -Method GET
        Assert-AvdResponse -Response $response -Description "GET $($result.nextLink)"
        $result = $response.Content | ConvertFrom-Json -Depth 64 @script:JsonDateArgs
    }
    $items.ToArray()
}

function Get-AvdPlanTime {
    <#
    .SYNOPSIS
    Current time in the scaling plan time zone (accepts Windows time zone IDs on any OS).
    #>
    [CmdletBinding()]
    [OutputType([System.DateTimeOffset])]
    param(
        [Parameter(Mandatory)] [string] $TimeZoneId
    )

    $zone = [System.TimeZoneInfo]::FindSystemTimeZoneById($TimeZoneId)
    [System.TimeZoneInfo]::ConvertTime([System.DateTimeOffset]::UtcNow, $zone)
}

function ConvertTo-AvdDateTimeOffset {
    <#
    .SYNOPSIS
    Normalizes an ARM timestamp. ConvertFrom-Json turns ISO strings into DateTime objects
    (PowerShell 7.4 and earlier) or keeps them as strings (7.5 with -DateKind String); this
    handles both, and treats timestamps without a zone as UTC like ARM does.
    #>
    [CmdletBinding()]
    [OutputType([System.DateTimeOffset])]
    param(
        [AllowNull()] [object] $Value
    )

    if ($null -eq $Value -or ($Value -is [string] -and [string]::IsNullOrWhiteSpace($Value))) { return $null }
    if ($Value -is [System.DateTimeOffset]) { return $Value }
    if ($Value -is [datetime]) {
        $dateTime = if ($Value.Kind -eq [System.DateTimeKind]::Unspecified) { [datetime]::SpecifyKind($Value, [System.DateTimeKind]::Utc) } else { $Value }
        return [System.DateTimeOffset]::new($dateTime)
    }
    [System.DateTimeOffset]::Parse([string]$Value, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal)
}

function Test-AvdSameTimestamp {
    <#
    .SYNOPSIS
    True when two ARM timestamps (for example session host configuration versions) are the same moment.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()] [object] $First,
        [AllowNull()] [object] $Second
    )

    $a = ConvertTo-AvdDateTimeOffset -Value $First
    $b = ConvertTo-AvdDateTimeOffset -Value $Second
    if ($null -eq $a -or $null -eq $b) { return $false }
    [math]::Abs(($a - $b).TotalSeconds) -lt 1
}

function ConvertTo-AvdLocalTime {
    <#
    .SYNOPSIS
    Formats an ARM timestamp in the scaling plan time zone, HH:mm by default.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()] [object] $Timestamp,
        [Parameter(Mandatory)] [string] $TimeZoneId,
        [string] $Format = 'HH:mm'
    )

    $instant = ConvertTo-AvdDateTimeOffset -Value $Timestamp
    if ($null -eq $instant) { return '' }
    $zone = [System.TimeZoneInfo]::FindSystemTimeZoneById($TimeZoneId)
    [System.TimeZoneInfo]::ConvertTime($instant, $zone).ToString($Format, [System.Globalization.CultureInfo]::InvariantCulture)
}

function Get-ShortName {
    <#
    .SYNOPSIS
    Session host or resource name for display: last segment of a resource ID, without a domain suffix.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()] [string] $Value
    )

    if (-not $Value) { return '' }
    (($Value -split '/')[-1] -split '\.')[0]
}

function Get-ImageVersionName {
    <#
    .SYNOPSIS
    Gallery image version name (for example 2.0.0) from an image version resource ID.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()] [string] $ImageVersionId
    )

    if (-not $ImageVersionId) { return '' }
    ($ImageVersionId -split '/')[-1]
}

#endregion

#region Session hosts and user sessions

function Get-AvdSessionHost {
    <#
    .SYNOPSIS
    Session hosts of a host pool, flattened for display.
    .NOTES
    Preview cmdlet equivalent: Get-AzWvdSessionHost.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $HostPoolId
    )

    foreach ($sessionHost in (Invoke-AvdApi -Path "$HostPoolId/sessionHosts" -All)) {
        $p = $sessionHost.properties
        [pscustomobject]@{
            Name            = Get-ShortName -Value $sessionHost.name
            Status          = [string]$p.status
            AllowNewSession = [bool]$p.allowNewSession
            Sessions        = [int]$p.sessions
            UpdateState     = [string]$p.updateState
            ConfigVersion   = $p.sessionHostConfiguration # timestamp of the configuration the host was built from
            LastHeartBeat   = $p.lastHeartBeat
            UpdateError     = [string]$p.updateErrorMessage
            ResourceId      = [string]$p.resourceId
        }
    }
}

function Get-AvdUserSession {
    <#
    .SYNOPSIS
    User sessions in a host pool.
    .NOTES
    Preview cmdlet equivalent: Get-AzWvdUserSession.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $HostPoolId
    )

    foreach ($session in (Invoke-AvdApi -Path "$HostPoolId/userSessions" -All)) {
        $parts = $session.id -split '/'
        [pscustomobject]@{
            SessionHost = Get-ShortName -Value $parts[-3]
            SessionId   = $parts[-1]
            User        = [string]$session.properties.userPrincipalName
            State       = [string]$session.properties.sessionState
            Created     = $session.properties.createTime
            Id          = $session.id
        }
    }
}

function Measure-AvdCapacity {
    <#
    .SYNOPSIS
    The capacity math autoscale uses: sessions divided by the slots on hosts that take new sessions.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()] [object[]] $SessionHost = @(),
        [Parameter(Mandatory)] [int] $MaxSessionLimit,
        [Parameter(Mandatory)] [int] $CapacityThresholdPct,
        [ValidateSet('RampUp', 'Peak', 'RampDown', 'OffPeak')] [string] $Phase = 'Peak'
    )

    $active = @($SessionHost | Where-Object { $_.Status -eq 'Available' -and $_.AllowNewSession })
    $sessions = [int](($active | Measure-Object -Property Sessions -Sum).Sum)
    $slots = $active.Count * $MaxSessionLimit
    $usedPct = if ($slots -gt 0) { [math]::Round(100 * $sessions / $slots) } else { 0 }
    $hostsNeeded = [int][math]::Ceiling($sessions / ($MaxSessionLimit * $CapacityThresholdPct / 100))

    [pscustomobject]@{
        ActiveHosts  = $active.Count
        TotalHosts   = @($SessionHost).Count
        Sessions     = $sessions
        Slots        = $slots
        UsedPct      = $usedPct
        ThresholdPct = $CapacityThresholdPct
        HostsNeeded  = $hostsNeeded
        Verdict      = if ($slots -eq 0) { 'no active hosts yet' }
                       elseif ($usedPct -gt $CapacityThresholdPct) { 'above threshold: autoscale adds a host' }
                       elseif ($usedPct -eq $CapacityThresholdPct) { 'exactly at threshold: autoscale holds' }
                       elseif ($Phase -eq 'RampUp') { 'below threshold: holds, no scale-in during ramp-up' }
                       else { 'below threshold: autoscale removes empty hosts where it can' }
    }
}

function Remove-AvdUserSession {
    <#
    .SYNOPSIS
    Signs out a user session (force).
    .NOTES
    Preview cmdlet equivalent: Remove-AzWvdUserSession -Force.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)] [string] $Id
    )

    process {
        if ($PSCmdlet.ShouldProcess($Id, 'Sign out user session')) {
            $null = Invoke-AvdApi -Path "${Id}?force=true" -Method DELETE
        }
    }
}

function Send-AvdUserMessage {
    <#
    .SYNOPSIS
    Pops up a message in a user session.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)] [string] $Id,
        [Parameter(Mandatory)] [string] $Title,
        [Parameter(Mandatory)] [string] $Message
    )

    process {
        if ($PSCmdlet.ShouldProcess($Id, 'Send message')) {
            $null = Invoke-AvdApi -Path "$Id/sendMessage" -Method POST -Body @{ messageTitle = $Title; messageBody = $Message }
        }
    }
}

#endregion

#region Session host configuration, management policy and update

function Get-AvdSessionHostConfiguration {
    <#
    .SYNOPSIS
    The session host configuration (WHAT). Use -Active for the configuration the current hosts were built from.
    .NOTES
    Preview cmdlet equivalent: Get-AzWvdSessionHostConfiguration.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $HostPoolId,
        [switch] $Active
    )

    $path = if ($Active) { "$HostPoolId/activeSessionHostConfigurations/default" } else { "$HostPoolId/sessionHostConfigurations/default" }
    Invoke-AvdApi -Path $path -AllowNotFound
}

function Get-AvdSessionHostManagement {
    <#
    .SYNOPSIS
    The session host management policy (HOW).
    .NOTES
    Preview cmdlet equivalent: Get-AzWvdSessionHostManagement.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $HostPoolId
    )

    Invoke-AvdApi -Path "$HostPoolId/sessionHostManagements/default" -AllowNotFound
}

function Set-AvdSessionHostImage {
    <#
    .SYNOPSIS
    Points the session host configuration at another gallery image version and waits until AVD has validated it.
    .NOTES
    Preview cmdlet equivalent: Update-AzWvdSessionHostConfiguration -ImageInfoType Custom -CustomInfoResourceId <id>.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $HostPoolId,
        [Parameter(Mandatory)] [string] $ImageVersionId,
        [int] $TimeoutMinutes = 15
    )

    $before = Get-AvdSessionHostConfiguration -HostPoolId $HostPoolId
    if (-not $before) {
        throw "Host pool $(Get-ShortName $HostPoolId) has no session host configuration yet."
    }
    if ($before.properties.imageInfo.customInfo.resourceId -eq $ImageVersionId) {
        Write-Verbose -Message 'Session host configuration already uses this image.'
        return $before
    }
    if (-not $PSCmdlet.ShouldProcess((Get-ShortName $HostPoolId), "Switch session host configuration to image $(Get-ImageVersionName $ImageVersionId)")) {
        return $before
    }

    $body = @{
        properties = @{
            friendlyName = "Image $(Get-ImageVersionName $ImageVersionId)"
            imageInfo    = @{
                type       = 'Custom'
                customInfo = @{ resourceId = $ImageVersionId }
            }
        }
    }
    $null = Invoke-AvdApi -Path "$HostPoolId/sessionHostConfigurations/default" -Method PATCH -Body $body

    # The PATCH is asynchronous: AVD validates the new configuration before it becomes the target.
    # Done when the image matches, the configuration got a new version (or was seen validating)
    # and the provisioning state is final.
    $started = Get-Date
    $deadline = $started.AddMinutes($TimeoutMinutes)
    $sawProvisioning = $false
    do {
        Start-Sleep -Seconds 10
        $after = Get-AvdSessionHostConfiguration -HostPoolId $HostPoolId
        $state = [string]$after.properties.provisioningState
        if ($state -eq 'Provisioning') { $sawProvisioning = $true }
        $imageMatches = $after.properties.imageInfo.customInfo.resourceId -eq $ImageVersionId
        $versionChanged = -not (Test-AvdSameTimestamp -First $after.properties.version -Second $before.properties.version)
        $final = $state -in 'Succeeded', 'Failed', 'Canceled'
        $settled = $imageMatches -and $final -and ($versionChanged -or $sawProvisioning -or ((Get-Date) - $started).TotalSeconds -ge 60)
        Write-Verbose -Message "Session host configuration: $state, image matches $imageMatches, new version $versionChanged"
    } until ($settled -or (Get-Date) -gt $deadline)

    if ($state -ne 'Succeeded') {
        throw "Session host configuration ended in state '$state'. Check the host pool's activity log and WVDErrors."
    }
    $after
}

function Get-AvdSessionHostUpdateStatus {
    <#
    .SYNOPSIS
    Status of the latest session host update, or $null if none ran yet.
    .NOTES
    Preview cmdlet equivalent: Get-AzWvdSessionHostManagementsUpdateStatus.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $HostPoolId
    )

    Invoke-AvdApi -Path "$HostPoolId/sessionHostManagements/default/sessionHostUpdateStatuses/default" -AllowNotFound
}

function Get-AvdProvisioningStatus {
    <#
    .SYNOPSIS
    Status of the latest provisioning run (hosts created through the management policy's instanceCount).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $HostPoolId
    )

    Invoke-AvdApi -Path "$HostPoolId/sessionHostManagements/default/sessionHostProvisioningStatuses/default" -AllowNotFound
}

function Test-AvdUpdateRunning {
    <#
    .SYNOPSIS
    True when a session host update is scheduled or in progress.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()] [object] $Status
    )

    [bool]($Status -and $Status.status -in $script:UpdateRunningStates)
}

function Start-AvdSessionHostUpdate {
    <#
    .SYNOPSIS
    Starts a session host update now, or schedules it (up to two weeks ahead).
    .NOTES
    Preview cmdlet equivalent: Invoke-AzWvdInitiateSessionHostUpdate.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $HostPoolId,
        [Nullable[datetime]] $StartAt,
        [string] $TimeZoneId
    )

    $body = @{}
    if ($StartAt) {
        $body.scheduledDateTime = ([datetime]$StartAt).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ', [System.Globalization.CultureInfo]::InvariantCulture)
        if ($TimeZoneId) { $body.scheduledDateTimeZone = $TimeZoneId }
    }
    $what = if ($StartAt) { "Schedule session host update at $StartAt" } else { 'Start session host update now' }
    if ($PSCmdlet.ShouldProcess((Get-ShortName $HostPoolId), $what)) {
        $null = Invoke-AvdApi -Path "$HostPoolId/sessionHostManagements/default/initiateSessionHostUpdate" -Method POST -Body $body
    }
}

function Invoke-AvdSessionHostUpdateControl {
    <#
    .SYNOPSIS
    Pause, resume, cancel, retry or start a session host update.
    .NOTES
    Preview cmdlet equivalent: Invoke-AzWvdControlSessionHostUpdate.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $HostPoolId,
        [Parameter(Mandatory)] [ValidateSet('Start', 'Pause', 'Resume', 'Cancel', 'Retry')] [string] $Action,
        [string] $CancelMessage
    )

    $body = @{ action = $Action }
    if ($Action -eq 'Cancel' -and $CancelMessage) { $body.cancelMessage = $CancelMessage }
    if ($PSCmdlet.ShouldProcess((Get-ShortName $HostPoolId), "$Action session host update")) {
        $null = Invoke-AvdApi -Path "$HostPoolId/sessionHostManagements/default/controlSessionHostUpdate" -Method POST -Body $body
    }
}

#endregion

#region Dynamic autoscaling

function Get-AvdScalingSchedule {
    <#
    .SYNOPSIS
    The pooled schedule of the demo scaling plan.
    .NOTES
    Preview cmdlet equivalent: Get-AzWvdScalingPlanPooledSchedule.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Environment
    )

    Invoke-AvdApi -Path "$($Environment.scalingPlan.id)/pooledSchedules/$($Environment.scalingPlan.scheduleName)"
}

function Get-AvdSchedulePhase {
    <#
    .SYNOPSIS
    Which phase the schedule is in right now, with the settings that apply in it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Schedule,
        [Parameter(Mandatory)] [string] $TimeZoneId
    )

    $p = $Schedule.properties
    $now = Get-AvdPlanTime -TimeZoneId $TimeZoneId
    $minute = $now.Hour * 60 + $now.Minute
    $starts = [ordered]@{
        RampUp   = $p.rampUpStartTime.hour * 60 + $p.rampUpStartTime.minute
        Peak     = $p.peakStartTime.hour * 60 + $p.peakStartTime.minute
        RampDown = $p.rampDownStartTime.hour * 60 + $p.rampDownStartTime.minute
        OffPeak  = $p.offPeakStartTime.hour * 60 + $p.offPeakStartTime.minute
    }
    $phase = 'OffPeak' # before ramp-up the previous off-peak still applies
    foreach ($name in $starts.Keys) {
        if ($minute -ge $starts[$name]) { $phase = $name }
    }
    $upSide = $phase -in 'RampUp', 'Peak'

    [pscustomobject]@{
        Phase                = $phase
        Now                  = $now.ToString('HH:mm')
        CapacityThresholdPct = if ($upSide) { [int]$p.rampUpCapacityThresholdPct } else { [int]$p.rampDownCapacityThresholdPct }
        MinimumActiveHostPct = if ($upSide) { [int]$p.rampUpMinimumHostsPct } else { [int]$p.rampDownMinimumHostsPct }
        MinHosts             = if ($upSide) { $p.createDelete.rampUpMinimumHostPoolSize } else { $p.createDelete.rampDownMinimumHostPoolSize }
        MaxHosts             = if ($upSide) { $p.createDelete.rampUpMaximumHostPoolSize } else { $p.createDelete.rampDownMaximumHostPoolSize }
        Times                = '{0:D2}:{1:D2} ramp-up, {2:D2}:{3:D2} peak, {4:D2}:{5:D2} ramp-down, {6:D2}:{7:D2} off-peak' -f `
            $p.rampUpStartTime.hour, $p.rampUpStartTime.minute, $p.peakStartTime.hour, $p.peakStartTime.minute,
            $p.rampDownStartTime.hour, $p.rampDownStartTime.minute, $p.offPeakStartTime.hour, $p.offPeakStartTime.minute
    }
}

function ConvertTo-AvdTime {
    <#
    .SYNOPSIS
    Minutes since midnight, or HH:mm, to the { hour, minute } object of the scaling plan API.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [object] $Value
    )

    if ($Value -is [string]) {
        $parts = $Value -split ':'
        return @{ hour = [int]$parts[0]; minute = [int]$parts[1] }
    }
    @{ hour = [int][math]::Floor($Value / 60); minute = [int]($Value % 60) }
}

function Get-AvdShiftedPhaseTime {
    <#
    .SYNOPSIS
    Start times (minutes since midnight) for ramp-up, peak, ramp-down and off-peak that put
    the schedule in the given phase at MinuteOfDay, all on the same day.
    #>
    [CmdletBinding()]
    [OutputType([int[]])]
    param(
        [Parameter(Mandatory)] [ValidateRange(0, 1439)] [int] $MinuteOfDay,
        [Parameter(Mandatory)] [ValidateSet('RampUp', 'Peak', 'RampDown', 'OffPeak')] [string] $Phase
    )

    # Minutes relative to now for ramp-up, peak, ramp-down and off-peak.
    $offsets = switch ($Phase) {
        'RampUp' { -1, 240, 300, 360 } # long ramp-up: no scale-in happens in this phase
        'Peak' { -2, -1, 120, 180 }
        'RampDown' { -3, -2, -1, 120 }
        'OffPeak' { -4, -3, -2, -1 }
    }
    [int[]] $times = foreach ($offset in $offsets) { $MinuteOfDay + $offset }
    # Squeeze later phases in before midnight, keeping one minute between them.
    for ($i = 3; $i -ge 0; $i--) {
        $latest = 1439 - (3 - $i)
        if ($times[$i] -gt $latest) { $times[$i] = $latest }
    }
    $index = @{ RampUp = 0; Peak = 1; RampDown = 2; OffPeak = 3 }[$Phase]
    $valid = $times[0] -ge 0 -and $times[$index] -le $MinuteOfDay -and ($index -eq 3 -or $times[$index + 1] -gt $MinuteOfDay)
    for ($i = 1; $i -le 3; $i++) {
        if ($times[$i] -le $times[$i - 1]) { $valid = $false }
    }
    if (-not $valid) {
        throw "No same-day schedule puts minute $MinuteOfDay in $Phase."
    }
    $times
}

function Set-AvdSchedulePhase {
    <#
    .SYNOPSIS
    Shifts the schedule times so that the scaling plan is in the given phase right now.
    Default restores the times and thresholds from the Bicep deployment.
    .NOTES
    Preview cmdlet equivalent: Update-AzWvdScalingPlanPooledSchedule. Changes apply immediately.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [object] $Environment,
        [Parameter(Mandatory)] [ValidateSet('RampUp', 'Peak', 'RampDown', 'OffPeak', 'Default')] [string] $Phase,
        [ValidateRange(1, 100)] [int] $RampUpCapacityThresholdPct
    )

    $defaults = $Environment.scalingPlan.schedule
    if ($Phase -eq 'Default') {
        $properties = @{
            rampUpStartTime              = ConvertTo-AvdTime -Value $defaults.rampUpStart
            peakStartTime                = ConvertTo-AvdTime -Value $defaults.peakStart
            rampDownStartTime            = ConvertTo-AvdTime -Value $defaults.rampDownStart
            offPeakStartTime             = ConvertTo-AvdTime -Value $defaults.offPeakStart
            rampUpCapacityThresholdPct   = [int]$defaults.rampUpCapacityThresholdPct
            rampDownCapacityThresholdPct = [int]$defaults.rampDownCapacityThresholdPct
        }
    }
    else {
        $now = Get-AvdPlanTime -TimeZoneId $Environment.timeZone
        try {
            $times = Get-AvdShiftedPhaseTime -MinuteOfDay ($now.Hour * 60 + $now.Minute) -Phase $Phase
        }
        catch {
            throw "Can't put the schedule in $Phase at $($now.ToString('HH:mm')) $($Environment.timeZone) without crossing midnight. Try again after 00:05 or before 23:55."
        }
        $properties = @{
            rampUpStartTime   = ConvertTo-AvdTime -Value $times[0]
            peakStartTime     = ConvertTo-AvdTime -Value $times[1]
            rampDownStartTime = ConvertTo-AvdTime -Value $times[2]
            offPeakStartTime  = ConvertTo-AvdTime -Value $times[3]
        }
    }
    if ($PSBoundParameters.ContainsKey('RampUpCapacityThresholdPct')) {
        $properties.rampUpCapacityThresholdPct = $RampUpCapacityThresholdPct
    }

    if ($PSCmdlet.ShouldProcess($Environment.scalingPlan.name, "Move schedule to $Phase")) {
        Invoke-AvdApi -Path "$($Environment.scalingPlan.id)/pooledSchedules/$($Environment.scalingPlan.scheduleName)" -Method PATCH -Body @{ properties = $properties }
    }
}

function Set-AvdAutoscale {
    <#
    .SYNOPSIS
    Turns autoscale on or off for the host pool in the demo scaling plan.
    .NOTES
    Preview cmdlet equivalent: Update-AzWvdScalingPlan -HostPoolReference @(@{ hostPoolArmPath = ...; scalingPlanEnabled = ... }).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [object] $Environment,
        [Parameter(Mandatory)] [bool] $Enabled
    )

    $body = @{
        properties = @{
            hostPoolReferences = @(
                @{ hostPoolArmPath = $Environment.poolA.id; scalingPlanEnabled = $Enabled }
            )
        }
    }
    $verb = if ($Enabled) { 'Enable' } else { 'Disable' }
    if ($PSCmdlet.ShouldProcess($Environment.poolA.name, "$verb autoscale")) {
        Invoke-AvdApi -Path $Environment.scalingPlan.id -Method PATCH -Body $body
    }
}

function Get-AvdAutoscaleDecision {
    <#
    .SYNOPSIS
    Latest autoscale evaluations for a host pool from WVDAutoscaleEvaluationPooled.
    Log Analytics ingestion usually lags a few minutes behind.
    #>
    [CmdletBinding()]
    [OutputType([System.Array])]
    param(
        [Parameter(Mandatory)] [object] $Environment,
        [Parameter(Mandatory)] [string] $HostPoolId,
        [int] $Last = 5,
        [int] $LookbackMinutes = 180
    )

    $query = @"
WVDAutoscaleEvaluationPooled
| where TimeGenerated > ago(${LookbackMinutes}m)
| where _ResourceId =~ '$HostPoolId'
| top $Last by TimeGenerated desc
| project TimeGenerated, Phase = ConfigSchedulePhase, Sessions = SessionCount, ActiveHosts = ActiveSessionHostCount,
          TotalHosts = TotalSessionHostCount, OccupancyPct = round(SessionOccupancyPercent),
          ThresholdPct = round(ConfigCapacityThresholdPercent), ResultType, Reason = ScalingReasonMessage
"@
    try {
        $result = Invoke-AzOperationalInsightsQuery -WorkspaceId $Environment.logAnalytics.customerId -Query $query -ErrorAction Stop
        @($result.Results)
    }
    catch {
        Write-Verbose -Message "Log Analytics query failed: $($_.Exception.Message)"
        @()
    }
}

#endregion

#region Console output

function Write-DemoTitle {
    <#
    .SYNOPSIS
    Writes a coloured heading for the live views.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Live console views for a presentation.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Text,
        [string] $Detail
    )

    Write-Host ''
    Write-Host " $Text " -ForegroundColor White -BackgroundColor DarkBlue -NoNewline
    if ($Detail) { Write-Host "  $Detail" -ForegroundColor Gray } else { Write-Host '' }
}

function Write-DemoLine {
    <#
    .SYNOPSIS
    Writes one label/value line for the live views.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Live console views for a presentation.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Label,
        [AllowEmptyString()] [string] $Value = '',
        [System.ConsoleColor] $Color = [System.ConsoleColor]::White
    )

    Write-Host ('  {0,-22}' -f $Label) -ForegroundColor DarkGray -NoNewline
    Write-Host $Value -ForegroundColor $Color
}

#endregion

Export-ModuleMember -Function @(
    'Resolve-AvdVmSize', 'Resolve-AvdDeploymentTarget', 'Get-DemoEnvironmentPath', 'Get-DemoEnvironment', 'Invoke-AvdApi', 'Get-AvdPlanTime',
    'ConvertTo-AvdDateTimeOffset', 'Test-AvdSameTimestamp', 'ConvertTo-AvdLocalTime', 'Get-ShortName', 'Get-ImageVersionName',
    'Get-AvdSessionHost', 'Get-AvdUserSession', 'Measure-AvdCapacity', 'Remove-AvdUserSession', 'Send-AvdUserMessage',
    'Get-AvdSessionHostConfiguration', 'Get-AvdSessionHostManagement', 'Set-AvdSessionHostImage',
    'Get-AvdSessionHostUpdateStatus', 'Get-AvdProvisioningStatus', 'Test-AvdUpdateRunning',
    'Start-AvdSessionHostUpdate', 'Invoke-AvdSessionHostUpdateControl',
    'Get-AvdScalingSchedule', 'Get-AvdSchedulePhase', 'ConvertTo-AvdTime', 'Get-AvdShiftedPhaseTime', 'Set-AvdSchedulePhase', 'Set-AvdAutoscale', 'Get-AvdAutoscaleDecision',
    'Write-DemoTitle', 'Write-DemoLine'
)
