# Functions
function log() {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$message
    )

    $ts = Get-Date -f "yyyy/MM/dd hh:mm:ss tt"
    Write-Output "$ts $message"
}

function CheckNuGetProvider {
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

function Install-LanguageOffline {
    # Installs a language from local files (no internet required).
    # Expects a per-language subfolder (named with the BCP-47 tag, e.g. "fr-CA")
    # under $SourceFolder containing:
    #   - the base language pack .cab and any Features on Demand .cab files
    #   - the Language Experience Pack .appx/.appxbundle (+ its License .xml)
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][string]$Language,
        [Parameter(Mandatory = $true)][string]$SourceFolder
    )

    $langFolder = Join-Path $SourceFolder $Language
    if (-not (Test-Path $langFolder)) {
        log " Offline source folder not found for ${Language}: $langFolder"
        return $false
    }

    # 1) Base language pack + Features on Demand (.cab). Apply the base
    #    language pack first (it is a prerequisite for the FoD capabilities).
    $cabs = Get-ChildItem -Path $langFolder -Filter *.cab -File |
        Sort-Object @{ Expression = { $_.Name -notmatch 'Language-Pack' } }, Name
    foreach ($cab in $cabs) {
        log " Adding package: $($cab.Name)"
        try {
            Add-WindowsPackage -Online -PackagePath $cab.FullName -NoRestart -ErrorAction Stop | Out-Null
        }
        catch {
            log "  Failed to add package $($cab.Name): $($_.Exception.Message)"
        }
    }

    # 2) Language Experience Pack (.appx / .appxbundle), pairing with a license
    #    .xml if one is present in the folder.
    $appxFiles = Get-ChildItem -Path $langFolder -File |
        Where-Object { $_.Extension -in '.appx', '.appxbundle' }
    $license = Get-ChildItem -Path $langFolder -Filter *.xml -File | Select-Object -First 1
    foreach ($appx in $appxFiles) {
        log " Provisioning appx: $($appx.Name)"
        try {
            if ($license) {
                Add-AppxProvisionedPackage -Online -PackagePath $appx.FullName -LicensePath $license.FullName -ErrorAction Stop | Out-Null
            }
            else {
                Add-AppxProvisionedPackage -Online -PackagePath $appx.FullName -SkipLicense -ErrorAction Stop | Out-Null
            }
        }
        catch {
            log "  Failed to provision appx $($appx.Name): $($_.Exception.Message)"
        }
    }

    return $true
}