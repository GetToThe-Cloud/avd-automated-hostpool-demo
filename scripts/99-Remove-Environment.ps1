#Requires -Version 7.2
<#
.SYNOPSIS
    Removes the demo environment.

.DESCRIPTION
    Turns autoscale off first (so it doesn't create hosts while you delete them), removes the
    AVD objects in dependency order, deletes the resource group, purges the soft-deleted Key Vault
    so you can redeploy with the same prefix, and removes the subscription role assignments this
    demo gave the AVD service principal.

.EXAMPLE
    ./99-Remove-Environment.ps1

.EXAMPLE
    ./99-Remove-Environment.ps1 -KeepAvdServicePrincipalRoles   # other host pools in the subscription use autoscale too
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive console script.')]
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [switch] $KeepAvdServicePrincipalRoles,

    [switch] $SkipKeyVaultPurge
)

$ErrorActionPreference = 'Stop'
Import-Module -Name (Join-Path $PSScriptRoot 'AvdDemo.psm1') -Force
$demo = Get-DemoEnvironment

if (-not $PSCmdlet.ShouldProcess($demo.resourceGroupName, 'Delete the demo resource group and everything in it')) { return }

Write-Host '  Turning autoscale off...'
try { $null = Set-AvdAutoscale -Environment $demo -Enabled $false -Confirm:$false } catch { Write-Warning $_.Exception.Message }

Write-Host '  Removing the AVD objects...'
$deletions = @(
    $demo.scalingPlan.id
    $demo.workspace.id
    $demo.poolA.appGroupId
    $demo.poolB.appGroupId
    "$($demo.poolA.id)?force=true" # force also removes the session host registrations
    "$($demo.poolB.id)?force=true"
)
foreach ($path in $deletions) {
    try { $null = Invoke-AvdApi -Path $path -Method DELETE -AllowNotFound } catch { Write-Warning $_.Exception.Message }
}

Write-Host "  Deleting resource group $($demo.resourceGroupName) (this takes a while)..."
$null = Remove-AzResourceGroup -Name $demo.resourceGroupName -Force

if (-not $SkipKeyVaultPurge) {
    Write-Host "  Purging Key Vault $($demo.keyVaultName)..."
    $purge = Invoke-AzRestMethod -Method POST -Path "/subscriptions/$($demo.subscriptionId)/providers/Microsoft.KeyVault/locations/$($demo.region)/deletedVaults/$($demo.keyVaultName)/purge?api-version=2024-11-01"
    if ($purge.StatusCode -ge 400) { Write-Warning "Purge returned HTTP $($purge.StatusCode): $($purge.Content)" }
}

if (-not $KeepAvdServicePrincipalRoles) {
    $avdSp = Get-AzADServicePrincipal -ApplicationId '9cdead84-a844-4324-93f2-b2e6bb768d07'
    $scope = "/subscriptions/$($demo.subscriptionId)"
    # Only the assignments this demo's Bicep created; they carry these descriptions.
    $ours = Get-AzRoleAssignment -ObjectId $avdSp.Id -Scope $scope -ErrorAction SilentlyContinue |
        Where-Object { $_.Scope -eq $scope -and $_.Description -like 'Dynamic autoscaling:*' }
    foreach ($assignment in $ours) {
        Write-Host "  Removing $($assignment.RoleDefinitionName) from the AVD service principal"
        $null = Remove-AzRoleAssignment -InputObject $assignment
    }
}

Remove-Item -Path (Get-DemoEnvironmentPath) -Force -ErrorAction SilentlyContinue
Write-Host "`n  Done.`n" -ForegroundColor Green
