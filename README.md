# PreFlight

PreFlight is a comprehensive Windows device configuration script designed for Autopilot provisioning. It automates device customization, debloating, and initial setup during the Windows Autopilot deployment process.

## Features

PreFlight performs 12 phases of device configuration:

- **UI Customization**: Desktop themes, wallpapers, lock screen, Start menu layout, and taskbar customization
- **Bloatware Removal**: Removes unwanted built-in Windows apps and provisioned packages
- **Time Zone Configuration**: Automatically configures device time zone
- **Windows Features Management**: Enable/disable optional Windows features
- **WinGet Application Installation**: Automated app deployment via WinGet
- **Autopilot v2 Optimization**: Disables privacy and voice screens for streamlined setup
- **Registry Tweaks**: Taskbar alignment, widgets management, Edge shortcuts, and more
- **Default User Profile**: Configures settings for all new users on the device

## Requirements

- Windows 10/11 device
- PowerShell 5.1 or later
- Administrator privileges
- Microsoft Intune (for deployment)
- Optional: Microsoft.WinGet.Client module (installed automatically when WinGet flag is enabled)

## Project Structure

```
PreFlight/
├── run.ps1                        # Main execution script
├── utils.ps1                      # Helper functions
├── config.json                    # Configuration file
├── Autopilot.theme                # Desktop theme file
├── Autopilot.jpg                  # Desktop wallpaper
├── AutopilotLock.jpg              # Lock screen wallpaper
├── TaskbarLayoutModification.xml  # Taskbar layout configuration
├── start2.bin                     # Start menu layout
└── settings.dat                   # Start menu settings
```

## Configuration

The `config.json` file controls all aspects of device configuration. Key sections include:

### Flags

Boolean flags to enable/disable specific features:

```json
{
  "Config": {
    "Flags": {
      "LeftAlignStart": true,        // Align Start button to left
      "WinGet": false,               // Enable WinGet app installation
      "DisableWidgets": true,        // Disable Windows widgets
      "StartLayout": true,           // Apply custom Start menu layout
      "TaskbarLayout": true,         // Apply custom taskbar layout
      "Desktop": true,               // Apply desktop theme/wallpaper
      "LockScreen": true,            // Apply lock screen wallpaper
      "APv2": false,                 // Enable Autopilot v2 optimizations
      "RemoveCopilotPWA": true,      // Remove Copilot PWA
      "SearchBar": 1                 // Search bar configuration
    }
  }
}
```

### Settings

Configuration options for various features:

```json
{
  "Settings": {
    "TimeZone": "",                  // Set specific timezone (empty = auto-detect)
    "RemoveApps": [                  // List of apps to remove
      "Microsoft.BingNews",
      "Microsoft.GamingApp",
      "Microsoft.XboxApp"
    ],
    "DisableOptionalFeatures": [],   // Windows features to disable
    "AddFeatures": [],               // Windows capabilities to add
    "WinGetInstall": []              // Apps to install via WinGet
  }
}
```

## Usage

### Local Execution (Testing)

Run the script locally with all configuration files in the same directory:

```powershell
# Navigate to the PreFlight directory
cd C:\Path\To\PreFlight

# Run with local files
powershell.exe -ExecutionPolicy Bypass -File .\run.ps1
```

### Intune Deployment

1. **Package the files**:
   - Create a folder containing all PreFlight files
   - Compress the folder into a `.zip` or `.intunewin` package

2. **Create Win32 App in Intune**:
   - Navigate to **Microsoft Intune admin center** > **Apps** > **Windows** > **Add**
   - Select **Windows app (Win32)**
   - Upload your package

3. **Install Command**:
   ```powershell
   powershell.exe -ExecutionPolicy Bypass -File .\run.ps1
   ```

4. **Uninstall Command** (optional):
   ```powershell
   cmd.exe /c echo "PreFlight uninstall"
   ```

5. **Detection Rule**:
   - Rule type: **File**
   - Path: `C:\ProgramData\IntuneDeviceConfig`
   - File or folder: `PreFlightInstalled.txt`
   - Detection method: **File or folder exists**

6. **Assign to Devices**:
   - Assign to Autopilot device groups
   - Set as required during Autopilot ESP (Enrollment Status Page)

### Azure Blob Storage Deployment (Future)

When using remote configuration from Azure Blob Storage:

```powershell
# Uncomment parameters in run.ps1 and use:
powershell.exe -ExecutionPolicy Bypass -File .\run.ps1 -Url "https://yourstorageaccount.blob.core.windows.net/container"
```

## Logging

PreFlight creates detailed logs for troubleshooting:

- **Location**: `C:\ProgramData\IntuneDeviceConfig\PreFlightLog_<timestamp>.log`
- **Detection File**: `C:\ProgramData\IntuneDeviceConfig\PreFlightInstalled.txt`
- **Transcript**: Full PowerShell transcript of execution

## Customization

### Adding Custom Wallpapers

1. Replace `Autopilot.jpg` (desktop wallpaper) and/or `AutopilotLock.jpg` (lock screen)
2. Update `Autopilot.theme` if needed to reference new file names

### Modifying Start Menu Layout

1. Configure Start menu on a reference device
2. Export layout: 
   ```powershell
   Export-StartLayout -Path "C:\Temp\Start2.bin"
   ```
3. Replace `start2.bin` with exported file

### Customizing Taskbar

1. Edit `TaskbarLayoutModification.xml` with desired pinned apps
2. Example structure:
   ```xml
   <LayoutModificationTemplate>
     <TaskbarPinList>
       <PinnedApp>Microsoft.WindowsCalculator_8wekyb3d8bbwe!App</PinnedApp>
     </TaskbarPinList>
   </LayoutModificationTemplate>
   ```

### Adding Apps to Remove

Edit `config.json` and add app package names to the `RemoveApps` array:

```json
"RemoveApps": [
  "Microsoft.YourPhone",
  "Microsoft.Office.OneNote"
]
```

To find app package names:
```powershell
Get-AppxProvisionedPackage -Online | Select-Object DisplayName, PackageName
```

## Execution Flow

1. **Phase 0**: Initialization
   - Create working directory
   - Copy configuration files
   - Start logging
   
2. **Phase 1**: Load default user registry
3. **Phase 2**: Apply UI customizations (theme, wallpapers, Start menu, taskbar)
4. **Phase 3**: Configure Spotlight behavior
5. **Phase 4**: Normalize taskbar settings
6. **Phase 5**: Set time zone
7. **Phase 6**: Remove bloatware apps
8. **Phase 7**: Prevent Edge desktop shortcuts
9. **Phase 8**: Remove OEM bookmarks
10. **Phase 9**: Customize Windows features
11. **Phase 10**: Install WinGet apps (if enabled)
12. **Phase 11**: Disable ADP screens (Autopilot v2)
13. **Phase 12**: Cleanup and finalize

## Troubleshooting

### Check Logs

View the most recent log file:
```powershell
Get-Content "C:\ProgramData\IntuneDeviceConfig\PreFlightLog_*.log" -Tail 50
```

### Common Issues

**Script fails during Intune deployment**:
- Verify execution policy allows script execution
- Check that all required files are included in package
- Review Intune app deployment logs in Event Viewer

**Apps not removed**:
- Verify app package names are correct
- Check if apps are user-installed vs provisioned
- Some apps require additional cleanup steps

**Custom Start menu not applied**:
- Ensure `StartLayout` flag is `true` in config.json
- Verify `start2.bin` file is valid
- Check Windows version compatibility

**Transcript errors**:
- Script includes fallback logging if transcript fails
- Check manual log file if transcript is unavailable

## Credits

Based on [AutopilotBranding](https://github.com/mtniehaus/AutopilotBranding) by Michael Niehaus

## Author

**Steve Weiner**  
Created: November 25, 2025  
Version: 1.0.0

## License

Standard licensing applies.

## Contributing

Contributions are welcome! Please ensure:
- Code follows existing style and structure
- All changes are tested on Windows 10/11
- Documentation is updated accordingly
