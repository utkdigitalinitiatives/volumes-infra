param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,
    [string]$TagKey = "AutoStop",
    [string]$TagValue = "true"
)

$ErrorActionPreference = "Stop"

# Authenticate using the Automation Account's managed identity
try {
    Connect-AzAccount -Identity | Out-Null
    Write-Output "Authenticated via managed identity."
}
catch {
    Write-Error "Failed to authenticate: $_"
    throw
}

# Scope the query to the resource group the managed identity actually has
# Contributor on. An unscoped Get-AzPostgreSqlFlexibleServer issues a
# subscription-wide request, which returns an empty set under RG-scoped
# permissions -- the runbook then reports success while stopping nothing.
$servers = Get-AzPostgreSqlFlexibleServer -ResourceGroupName $ResourceGroupName | Where-Object {
    $_.Tag[$TagKey] -eq $TagValue
}

if (-not $servers) {
    # Treated as a failure, not a clean exit. This runbook exists because
    # something is expected to be stopped; finding nothing means either the tag
    # is missing or the identity cannot see the servers, and both need a human.
    throw "No PostgreSQL Flexible Servers found in resource group '$ResourceGroupName' with tag ${TagKey}=${TagValue}. Check the tag and the automation identity's role assignment."
}

$failed = @()

foreach ($server in $servers) {
    $name = $server.Name
    $rg = $server.ResourceGroupName
    $state = $server.State

    if ($state -eq "Ready") {
        Write-Output "Stopping server '$name' in resource group '$rg' (state: $state)..."
        try {
            Stop-AzPostgreSqlFlexibleServer -Name $name -ResourceGroupName $rg -NoWait
            Write-Output "Stop command sent for '$name'."
        }
        catch {
            Write-Output "Failed to stop '$name': $_"
            $failed += $name
        }
    }
    else {
        Write-Output "Skipping server '$name' (state: $state)."
    }
}

if ($failed.Count -gt 0) {
    throw "Failed to stop: $($failed -join ', ')"
}
