<#
.SYNOPSIS
Configures initial settings during Autopilot provisioning for Windows PC.

.DESCRIPTION
InitialDeviceConfig invokes a json file from blob storage or uses a local config.json file with instructions on what to modify on the system.

.PARAMETER UseLocal
Use the local config.json file instead of downloading from blob storage

.PARAMETER Debloat
Specify the Debloat parameter to remove built in Windows apps

.PARAMETER Customize
Specify the Customize parameter to modify visual elements of Windows including desktop wallpaper (preference), lock screen wallpaper, Start menu, and taskbar customization 

.EXAMPLES
.EXAMPLE
PS> run.ps1
Runs InitialDeviceConfig and downloads config.json from blob storage (default behavior)

.EXAMPLE
PS> run.ps1 -UseLocal
Runs InitialDeviceConfig using the local config.json file from the DeviceConfig directory

.EXAMPLE
PS> run.ps1 -DeBloat
Runs InitialDeviceConfig with the option to uninstall unwanted, built-in Windows apps

.EXAMPLE
PS> run.ps1 -Customize -UseLocal
Runs InitialDeviceConfig with customizations using the local config.json file

.NOTES
Author: Steve Weiner
Created: 2025-11-25
Version: 1.0.0
Dependencies: List modules or external requirements.
License: Standard licensing applies.
Notes: Based on AutopilotBranding, by Michael Niehaus

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

$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Definition
. "$scriptPath\utils.ps1"

# Determine config source and load configuration
$configPath = "C:\ProgramData\IntuneDeviceConfig"
$configFile = Join-Path $configPath "config.json"

if ($UseLocal) {
    Write-Host "Using local config.json file..." -ForegroundColor Cyan
    $localConfigPath = Join-Path $PSScriptRoot "config.json"
    
    if (-not (Test-Path -Path $localConfigPath)) {
        Write-Error "Local config.json not found at: $localConfigPath"
        exit 1
    }
    
    # Create target directory if it doesn't exist
    if (-not (Test-Path -Path $configPath)) {
        New-Item -Path $configPath -ItemType Directory -Force | Out-Null
    }
    
    # Copy local config to working directory
    Copy-Item -Path $localConfigPath -Destination $configFile -Force
    Write-Host "Local config.json copied successfully" -ForegroundColor Green
}
else {
    Write-Host "Downloading config.json from blob storage..." -ForegroundColor Cyan

    $blobUrl = $Url
    
    # Create target directory if it doesn't exist
    if (-not (Test-Path -Path $configPath)) {
        New-Item -Path $configPath -ItemType Directory -Force | Out-Null
    }
    
    # Download config.json from blob storage
    try {
        Invoke-WebRequest -Uri "$($blobUrl)\config.json" -OutFile $configFile -ErrorAction Stop
        Write-Host "Config downloaded successfully from: $blobUrl" -ForegroundColor Green
    }
    catch {
        Write-Error "Failed to download config from blob storage: $_"
        exit 1
    }
}

# Load the configuration
try {
    $config = Get-Content -Path $configFile -Raw | ConvertFrom-Json
    Write-Host "Configuration loaded successfully" -ForegroundColor Green
}
catch {
    Write-Error "Failed to parse config.json: $_"
    exit 1
}

# Check architecture
if ("$env:PROCESSOR_ARCHITEW6432" -ne "ARM64") {
    if (Test-Path "$($env:WINDIR)\SysNative\WindowsPowerShell\v1.0\powershell.exe") {
        & "$($env:WINDIR)\SysNative\WindowsPowerShell\v1.0\powershell.exe" -ExecutionPolicy bypass -NoProfile -File "$PSCommandPath"
        Exit $LASTEXITCODE
    }
}

# Start logging
Start-Transcript "$($env:ProgramData)\IntuneDeviceConfig\DeviceConfig.log"

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