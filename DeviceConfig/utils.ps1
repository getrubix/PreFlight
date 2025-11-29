# Functions
function log() {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$message
    )

    $ts = Get-Date -f "yyyy/MM/dd hh:mm:ss tt"
    Write-Output "$ts $message"`
}

function Check-NuGetProvider {
    [CmdletBinding()]
    param (
        [version]$MinimumVersion = [version]'2.8.5.201'
    )
    $provider = Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue | Sort-Object Version -Descending | Select-Object -First 1

    if (-not $provider) {
        log "NuGet Provider Package not detected, installing..."
        Install-PackageProvider -Name NuGet -Confirm:$false -Force | Out-Null
    } elseif ($provider.Version -lt $MinimumVersion) {
        log "NuGet provider v$($provider.Version) is less than required v$($MinimumVersion); updating..."
        Install-PackageProvider -Name NuGet -Confirm:$false -Force | Out-Null
    } else {
        log "NuGet provider is installed and updated."
    }
}