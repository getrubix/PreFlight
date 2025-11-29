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
    [string]$Url,
    
    [Parameter(Mandatory = $false)]
    [switch]$Debloat,
    
    [Parameter(Mandatory = $false)]
    [switch]$Customize
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
        "start2.bin"
        "TaskbarLayoutModification.xml"
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

    # Apply a custom start menu and taskbar layout
    
}

