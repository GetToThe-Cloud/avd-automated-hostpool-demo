@{
    # PSScriptAnalyzer configuration. Every default rule is on.
    #
    # Write-Host is used on purpose in the console scripts and the live views:
    # their output is for a presenter at a terminal, not objects for a pipeline.
    # Each of those scripts and functions carries a SuppressMessage attribute
    # that says so, instead of a blanket exclusion here.
    Rules = @{
        PSUseCompatibleSyntax = @{
            Enable = $true
            # The scripts need PowerShell 7.2 or later.
            TargetVersions = @('7.0')
        }
    }
}
