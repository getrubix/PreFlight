<#
.SYNOPSIS
Configures Windows devices during Autopilot provisioning with comprehensive customization and debloating capabilities.

.DESCRIPTION
PreFlight DeviceConfig automates Windows device setup during Autopilot provisioning by loading a configuration file (config.json) 
from Azure blob storage or local file system. The script performs 12 phases of customization including:
- UI customization (themes, wallpapers, lock screen, Start menu, taskbar)
- Bloatware removal (built-in apps and provisioned packages)
- Time zone configuration
- Windows optional features management
- WinGet application installation
- Autopilot v2 optimization (disabled privacy/voice screens)
- Registry tweaks for improved user experience (taskbar alignment, widgets, Edge shortcuts)
- Default user profile configuration

.PARAMETER UseLocal
Use the local config.json file from the script directory instead of downloading from blob storage.

.PARAMETER Url
The Azure blob storage URL to download config.json and customization assets from. Required when not using -UseLocal.

.EXAMPLES
.EXAMPLE
PS> run.ps1 -Url "https://mystorageaccount.blob.core.windows.net/container"
Downloads config.json from the specified blob storage URL and applies all configured settings.

.EXAMPLE
PS> run.ps1 -UseLocal
Uses the local config.json file from the DeviceConfig directory for all configuration.

.NOTES
Author: Steve Weiner
Created: 2025-11-25
Version: 1.0.0
Dependencies: Microsoft.WinGet.Client module (installed automatically when WinGet flag is enabled)
License: Standard licensing applies.
Notes: Based on AutopilotBranding by Michael Niehaus. Creates logs at C:\ProgramData\IntuneDeviceConfig\PreFlightLog_<timestamp>.log

#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [switch]$UseLocal,

    [Parameter(Mandatory = $false)]
    [string]$Url
)

# =======================================
# PHASE 0: Preparing
# =======================================

$ErrorActionPreference = "Stop"

$startUtc = [datetime]::UtcNow

$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Definition
. "$scriptPath\utils.ps1"

# Determine config source and load configuration
$configPath = "C:\ProgramData\IntuneDeviceConfig"
$configFile = Join-Path $configPath "config.json"
$date = Get-Date -Format "MM-dd-yyyy HH-mm"

Start-Transcript -Path "$($configPath)\PreFlightLog_$($date).log"
New-Item -Path $configPath -ItemType File -Name "PreFlightInstalled.txt" -Force

if ($UseLocal) {
    log "Using local config.json file..." -ForegroundColor Cyan
    $localConfigPath = Join-Path $PSScriptRoot "config.json"
    
    if (-not (Test-Path -Path $localConfigPath)) {
        log "Local config.json not found at: $localConfigPath"
        exit 1
    }
    
    # Create target directory if it doesn't exist
    if (-not (Test-Path -Path $configPath)) {
        log -Path $configPath -ItemType Directory -Force | Out-Null
    }
    
    # Copy local config to working directory
    Copy-Item -Path $localConfigPath -Destination $configFile -Force
    log "Local config.json copied successfully" -ForegroundColor Green
}
else {
    log "Downloading config.json from blob storage..." -ForegroundColor Cyan

    $blobUrl = $Url
    
    # Create target directory if it doesn't exist
    if (-not (Test-Path -Path $configPath)) {
        New-Item -Path $configPath -ItemType Directory -Force | Out-Null
    }
    
    # Download config.json from blob storage
    try {
        Invoke-WebRequest -Uri "$($blobUrl)\config.json" -OutFile $configFile -ErrorAction Stop
        log "Config downloaded successfully from: $blobUrl" -ForegroundColor Green
    }
    catch {
        log "Failed to download config from blob storage: $_"
        exit 1
    }
}

# Load the configuration
try {
    $config = Get-Content -Path $configFile -Raw | ConvertFrom-Json
    log "Configuration loaded successfully" -ForegroundColor Green
}
catch {
    log "Failed to parse config.json: $_"
    exit 1
}

# Check architecture
if ("$env:PROCESSOR_ARCHITEW6432" -ne "ARM64") {
    if (Test-Path "$($env:WINDIR)\SysNative\WindowsPowerShell\v1.0\powershell.exe") {
        & "$($env:WINDIR)\SysNative\WindowsPowerShell\v1.0\powershell.exe" -ExecutionPolicy bypass -NoProfile -File "$PSCommandPath"
        Exit $LASTEXITCODE
    }
}

# Exit if during OOBE
$TypeDef = @"
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace Api
{
    public class Kernel 32
    {
        [DllImport("kernel32.dll", CharSet = CharSet.Auo, SetLastError = true)]
        public static extern int OOBEComplete(ref int bIsOOBEComplete);
    }
}
"@
Add-Type -TypeDefinition $TypeDef -Language CSharp
$IsOOBEComplete = $false
$null = [Api.kernel32]::OOBEComplete([ref] $IsOOBEComplete)
if ($IsOOBEComplete) {
    log "OOBE is completed, exiting withing configuring."
    Stop-Transcript
    exit 0
}

# =======================================
# PHASE 1: LOAD DEFAULT USER REGISTRY
# =======================================
log "Loading default user registry hive NTUSER.DAT (TempUser)"
reg.exe load HKLM\TempUser "C:\Users\Default\NTUSER.DAT" | Out-Null

# =======================================
# PHASE 2: CUSTOMIZATION
# =======================================
log "Checking if Customize is enabled..."
if ($Customize) {
    log "Customize is enabled, getting assets..."
    $customFiles = @(
        "DeviceConfig.theme"
        "Start2.bin"
        "TaskbarLayoutModification.xml"
        "settings.dat"
        "Autopilot.theme"
        "Autopilot.jpg"
        "AutopilotLock.jpg"
    )
    if ($UseLocal) {
        foreach ($file in $customFiles) {
            Copy-Item -Path "$($PSScriptRoot)\$($file)" -Destination "$($configPath)\$($file)" -Recurse -Force 
        }    
    } else {
        foreach ($file in $customFiles) {
            Invoke-WebRequest -Uri "$($blobUrl)\$($file)" -OutFile "$($configPath)\$($file)"
        }
    }

    # Apply a custom start menu
    if ($config.Config.Flags.StartLayout) {
        log "Copying Start menu layout"
        $localStatePath = "C:\Users\Default\AppData\Local\Packages\Microsoft.Windows.StartMenuExperienceHost_cw5n1h2txyewy\LocalState"
        mkdir -Path $localStatePath -Force -ErrorAction SilentlyContinue | Out-Null
        Copy-Item "$($configPath)\Start2.bin" "$($localStatePath)\Start2.bin" -Force
        log "Copying Start menu settings"
        $settingsPath = "C:\Users\Default\AppData\Local\Packages\Microsoft.Windows.StartMenuExperienceHost_cw5n1h2txyewy\Settings"
        mkdir -Path $settingsPath -Force -ErrorAction SilentlyContinue | Out-Null
        Copy-Item "$($configPath)\settings.dat" "$($settingsPath)\Settings.settings.dat" -Force
    } else {
        log "Skipping Start layout"
    }

    # Taskbar
    if ($config.Config.Flags.TaskbarLayout) {
        log "Importing Taskbar Layout"
        $OEMPath = "C:\Windows\OEM"
        mkdir -Path $OEMPath -Force -ErrorAction SilentlyContinue | Out-Null
        Copy-Item "$($configPath)\TaskbarLayoutModification.xml" "$($OEMPath)\TaskbarLayoutModification.xml" -Force & reg.exe add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer" /v LayoutXMLPath /t REG_EXPAND_SZ /d "%SystemRoot%\OEM\TaskbarLayoutModification.xml" /f /reg:64 | Out-Null
        Log "Unpin Microsoft Store app from taskbar"
        & reg.exe add "HKLM\TempUser\Software\Policies\Microsoft\Windows\Explorer" /v NoPinningStoreToTaskbar /t REG_DWORD /d 1 /f /reg:64 | Out-Null
    } else {
        Log "Skipping Taskbar Layout"
    }

    # Configure desktop background
    if ($config.Config.Flags.Theme) {
        log "Setting desktop background"
        $OEMThemes = "C:\Windows\Resources\OEM Themes"
        mkdir $OEMThemes -Force | Out-Null
        Copy-Item "$($configPath)\Autopilot.theme" "$($OEMThemes)\Autopilot.theme" -Force
        $wallpaperPath = "C:\Windows\web\wallpaper\Autopilot"
        mkdir $wallpaperPath -Force | Out-Null
        Copy-Item "$($configPath)\Autopilot.jpg" "$($wallpaperPath)\Autopilot.jpg" -Force
        log "Setting Autopilot theme as new user default"
        & reg.exe add "HKLM\TempUser\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes" /v InstallTheme /t REG_EXPAND_SZ /d "%SystemRoot%\resources\OEM Themes\Autopilot.theme" /f /reg:64 | Out-Null
        & reg.exe add "HKLM\TempUser\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes" /v CurrentTheme /t REG_EXPAND_SZ /d "%SystemRoot%\resources\OEM Themes\Autopilot.theme" /f /reg:64 | Out-Null
    } else {
        log "Skipping desktop background"
    }

    if ($config.Config.Flags.LockScreen) {
        log "Configuring lock screen image"
        $RegPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP"
        $wallpaperPath = "C:\Windows\web\wallpaper\Autopilot"
        mkdir $wallpaperPath -Force | Out-Null
        Copy-Item "$($configPath)\AutopilotLock.jpg" "$($wallpaperPath)\AutopilotLock.jpg"
        $LockScreenImage = "C:\Windows\web\wallpaper\Autopilot\AutopilotLock.jpg"
        if (!(Test-Path -Path $RegPath)) {
            New-Item -Path $RegPath -Force | Out-Null
        }
        New-ItemProperty -Path $RegPath -Name LockScreenImagePath -Value $LockScreenImage -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $RegPath -Name LockScreenImageUrl -Value $LockScreenImage -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $RegPath -Name LockScreenImageStatus -Value 1 -PropertyType DWORD -Force | Out-Null
    } else {
        log "Skipping lock screen image"
    }
}

# =======================================
# PHASE 3: SPOTLIGHT BEHAVIOR
# =======================================

# Stop Start menu from opening on first logon
& reg.exe add "HKLM\TempUser\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v StartShownOnUpgrade /t REG_DWORD /d 1 /f /reg:64 | Out-Null

# Hide "Lean more about this picture" from desktop
& reg.exe add "HKLM\TempUser\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel" /v "{2cc5ca98-6485-489a-920e-b3e88a6ccce3}" /t REG_DWORD /d 1 /f /reg:64 | Out-Null

# Disable Windows Spotlight so wallpaper works
log "Disabling Windows Spotlight for Desktop"
& reg.exe add "HKLM\TempUser\Software\Policies\Microsoft\Windows\CloudContent" /v DisableSpotlightCollectionOnDesktop /t REG_DWORD /d 1 /f reg:64 | Out-Null

# =======================================
# PHASE 4: NORMALIZE TASKBAR
# =======================================

# Left align start button (users can still change back)
if ($config.Config.Flags.LeftAlignStart) {
    log "Configuring left aligned Start menu"
    & reg.exe add "HKLM\TempUser\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v TaskbarAl /t REG_DWORD /d 0 /f /reg:64 | Out-Null
} else {
    log "Skipping left align start"
}

# Hide widgets
if ($config.Config.Flags.HideWidgets) {
    try {
        log "Attempting to Hide widgets via Reg Key"
        $output = & reg.exe add "HKLM\TempUser\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v TaskbarDa /t REG_DWORD /d 0 /f /reg:64
        if ($LASTEXITCODE -ne 0) {
            throw $output
        }
        log "Widgets Hidden Completed"
    } 
    catch {
        $errorMessage = $_.Exception.Message
        log "First attempt error: $errorMessage"
        if ($errorMessage -like '*Access is denied*') {
            log "UCPD driver may be active"
            log "Attempting Widget Hiding workaround (TaskbarDa)"
            $regExePath = (Get-Command reg.exe).Source
            $tempRegExe = "$($env:TEMP)\reg1.exe"
            Copy-Item -Path $regExePath -Destination $tempRegExe -Force -ErrorAction Stop
            & $tempRegExe add "HKLM\TempUser\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v TaskbarDa /t REG_DWORD /d 0 /f /reg:64 | Out-Null
            Remove-Item $tempRegExe -Force -ErrorAction SilentlyContinue
            log 'Widget Workaround complete'
        }
    }
} else {
    log "Skipping hiding widgets"
}

# Disable Widgets (user cannot enable)
if ($config.Config.Flags.DisableWidgets) {
    log "Disabling Widgets"
    $dshPath = "HKLM:\Software\Policies\Microsoft\Dsh"
    if (-not (Test-Path $dshPath)) {
        New-Item -Path $dshPath | Out-Null
    }
    Set-ItemProperty -Path $dshPath -Name "DisableWidgetsOnLockScreen" -Value 1
    Set-ItemProperty -Path $dshPath -Name "DisableWidgetsBoard" -Value 1
    Set-ItemProperty -Path $dshPath -Name "AllowNewsAndInterests" -Value 0
}

# Disable network location fly-out
log "Turning off network location notification"
& reg.exe add "HKLM\SYSTEM\CurrentControlSet\Control\Network\NewNetworkWindowOff" /f /reg:64 | Out-Null

# =======================================
# PHASE 5: SET TIME ZONE
# =======================================
if (![string]::IsNullOrEmpty($config.Config.Settings.TimeZone)) {
    Log "Setting time zone: $($config.Config.Settings.TimeZone)"
    Set-TimeZone -Id $config.Config.Settings.TimeZone
} else {
    # Enable locations services so time zone will be set automatically
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location" -Name "Value" -Type "String" -Value "Allow" -Force
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Sensor\Overrides\{BFA794E4-F964-4FDB-90F6-51056BFE4B44}" -Name "SensorPermissionState" -Type "DWord" -Value 1 -Force
    Start-Service -Name "lfsvc" -ErrorAction SilentlyContinue
}

# =======================================
# PHASE 6: REMOVE BLOATWARE
# =======================================

# Remove specific apps
log "Removing bloatware"
$apps = Get-AppxProvisionedPackage -online
$bloatware = $config.Config.Settings.RemoveApps
$bloatware | ForEach-Object {
    $current = $_
    $apps | Where-Object { $_.DisplayName -eq $current } | ForEach-Object {
        try {
            log "Removing provisioned app: $current"
            $_ | Remove-AppxProvisionedPackage -Online -AllUsers -ErrorAction SilentlyContinue | Out-Null
        }
        catch { }
    }
}

# Remove Copilot PWA
if ($config.Config.Flags.RemoveCopilotPWA) {
    log "Removing specified in-box provisioned apps"
    reg.exe add "HKLM\TempUser\Software\Microsoft\Windows\CurrentVersion\Explorer\AutoInstalledPWAs" /v CopilotPWAPreinstallCompleted /t REG_DWORD /d 1 /f /reg:64
}

# ===========================================
# PHASE 7: PREVENT EDGE DESKTOP SHORTCUT
# ===========================================
log "Turning off (old) Edge desktop shortcut"
& reg.exe add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer" /v DisableEdgeDesktopShortcutCreation /t REG_DWORD /d 1 /f /reg:64 | Out-Null
log "Turning off Edge desktop icon"
& reg.exe add "HKLM\SOFTWARE\Policies\Microsoft\EdgeUpdate" /v "CreateDesktopShortcutDefault" /t REG_DWORD /d 0 /f /reg:64 | Out-Null
& reg.exe add "HKLM\SOFTWARE\Policies\Microsoft\EdgeUpdate" /v "RemoveDesktopShortcutDefault" /t REG_DWORD /d 2 /f /reg:64 | Out-Null
if (Test-Path "C:\Users\Public\Desktop\Microsoft Edge.lnk") {
    log "Removing Edge desktop shortcut"
    Remove-Item "C:\Users\Public\Desktop\Microsoft Edge.lnk" -Force
}

# ===========================================
# PHASE 8: REMOVE OEM BOOKMARKS (EDGE)
# ===========================================
$bookmarks = "C:\Users\Default\AppData\Local\Microsoft\Edge\User Data\Default\Bookmarks"
if (Test-Path $bookmarks) {
    log "Removing Edge bookmarks from default profile"
    Remove-Item $bookmarks -Recurse -Force
}
$Bookmarksregpath = "HKLM:\SOFTWARE\Microsoft\MicrosoftEdge\Main\FavoriteBarItems"
if (Test-Path $Bookmarksregpath) {
    Remove-Item -Path $Bookmarksregpath -Recurse -Force
    log "OEM bookmarks detected and removed"
} else {
    log "OEM bookmarks not found"
}

# ===========================================
# PHASE 9: CUSTOMIZE WINDOWS FEATURES
# ===========================================

# Disable optional features
$DisableOptionalFeatures = $config.Config.Settings.DisableOptionalFeatures
if ($DisableOptionalFeatures.count -gt 0) {
    try {
        $EnabledOptionalFeatures = Get-WindowsOptionalFeature -Online | Where-Object { $_.State -eq "Enabled" }
        foreach ($EnabledFeature in $EnabledOptionalFeatures) {
            if ($DisableOptionalFeatures -contains $EnabledFeature.FeatureName) {
                log "Disabling optional feature: $($EnabledFeature.FeatureName)"
                try {
                    Disable-WindowsOptionalFeature -Online -FeatureName $EnabledFeature.FeatureName -NoRestart | Out-Null
                }
                catch {}
            }
        }
    } catch {
        log "Unexpected error querying Windows optional features: $_"
    }
}

# Add features on demand
$AddFeatures = $config.Config.Settings.AddFeatures
if ($AddFeatures.count -gt 0) {
    foreach ($Feature in $AddFeatures) {
        log "Adding Windows feature: $Feature"
        try {
            $result = Add-WindowsCapability -Online -Name $Feature
            if ($result.RestartNeeded) {
                log " Feature $Feature was installed requires a restart"
            }
        }
        catch {
            log " Unable to add Windows capability: $Feature"
        }
    }
}

# ===========================================
# PHASE 10: INSTALL WINGET APPS
# ===========================================
if ($config.Config.Flags.WinGet) {
    CheckNuGetProvider

    log "Installing WinGet.Client module"
    Install-Module -Name Microsoft.WinGet.Client -Force -Scope AllUsers -Repository PSGallery | Out-Null
    log "Installing latest Winget package and dependencies"
    Repair-WinGetPackageManager -Force -Latest | Out-Null
    $VCppRedistributable_Url = "https://aka.ms/vs/17/release/vc_redist.x64.exe"
    $VCppRedistributable_Path = Join-Path $configPath "vc_redist.x64.exe"

    Invoke-WebRequest -Uri $VCppRedistributable_Url -OutFile $VCppRedistributable_Path -UseBasicParsing
    Start-Process -FilePath $VCppRedistributable_Path -ArgumentList "/install", "/quiet", "/norestart" -Wait

    $WinGetResolve = Resolve-Path "C:\Program Files\WindowsApps\Microsoft.DesktopAppInstaller_*__8wekyb3d8bbwe\winget.exe"
    $wingetExe = $WinGetResolve[-1].Path
    $wingetVer = & "$wingetExe" --version
    log "Winget version is: $wingetVer"

    Remove-Item $VCppRedistributable_Path -Force

    $WinGetInstall = $config.Config.Settings.WinGetInstall
    if ($WinGetInstall.count -gt 0) {
        foreach ($app in $WinGetInstall) {
            log "WinGet installing: $app"
            try {
                & "$wingetExe" install $app --silent --scope machine --accept-package-agreements --accept-source-agreements
            }
            catch {
                log "Winget installing error: $($_.Exception.Message)"
            }
        }
    } else {
        Log "Skipping WinGet installs"
    }
}

# ===========================================
# PHASE 11: DISABLE ADP SCREENS (APv2 ONLY)
# ===========================================
if ($config.Config.Flags.APv2) {
    $registryPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE"
    New-ItemProperty -Path $registryPath -Name "DisablePrivacyExperience" -Value 1 -PropertyType DWORD -Force | Out-Null
    New-ItemProperty -Path $registryPath -Name "DisableVoice" -Value 1 -PropertyType DWORD -Force | Out-Null
    New-ItemProperty -Path $registryPath -Name "PrivacyConsentStatus" -Value 1 -PropertyType DWORD -Force | Out-Null
    New-ItemProperty -Path $registryPath -Name "ProtectYourPC" -Value 3 -PropertyType DWORD -Force | Out-Null
    log "APv2 extra pages disabled"
} else {
    log "Skipping APv2 modification"
}

# ====================
# PHASE 12: CLEANUP
# ====================

# Unload default user registry
log "Unloading default user registry hive"
reg.exe unload HKLM\TempUser | Out-Null

# Skip first sign-in animation
log "Skipping first sign-in animation"
$registryPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
New-ItemProperty -Path $registryPath -Name "EnableFirstLogonAnimation" -Value 0 -PropertyType DWORD -Force | Out-Null
New-ItemProperty -Path $registryPath -Name "DelayedDesktopSwitchTimeout" -Value 0 -PropertyType DWORD -Force | Out-Null

$stopUtc = [datetime]::UtcNow

# Calculate run time
$runTime = $stopUtc - $startUtc

if ($runTime.TotalHours -ge 1) {
    $runTimeFormatted = 'Duration: {0:hh} hr {0:mm} min {0:ss} sec' -f $runTime
}
else {
    $runTimeFormatted = 'Duration: {0:mm} min {0:ss} sec' -f $runTime
}

log "PreFlight complete"
log "Total Script time: $($runTimeFormatted)"

Stop-Transcript