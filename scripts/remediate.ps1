# remediate.ps1 - Re-apply all post-install configuration (idempotent)
# Mirrors the FirstLogonCommands from autounattend.xml

$ErrorActionPreference = "Continue"

Write-Output "=== Remediation start ==="

# --- RDP ---
Write-Output "Configuring RDP..."
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0
Enable-NetFirewallRule -DisplayGroup 'Remote Desktop'

# --- SSH ---
Write-Output "Configuring SSH..."
$sshCap = Get-WindowsCapability -Online | Where-Object { $_.Name -match 'OpenSSH.Server' -and $_.State -ne 'Installed' }
if ($sshCap) { Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 }
Start-Service sshd -ErrorAction SilentlyContinue
Set-Service -Name sshd -StartupType Automatic
$rule = Get-NetFirewallRule -Name sshd -ErrorAction SilentlyContinue
if (-not $rule) {
    New-NetFirewallRule -Name sshd -DisplayName 'OpenSSH Server' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22
}

# --- ICMP ---
netsh advfirewall firewall add rule name="Allow ICMPv4" protocol=icmpv4:8,any dir=in action=allow 2>$null

# --- Firewall off ---
Write-Output "Disabling firewall..."
Set-NetFirewallProfile -All -Enabled False

# --- Hibernate off ---
powercfg /h off

# --- SAC / EMS ---
Write-Output "Configuring SAC/EMS..."
bcdedit /emssettings emsport:1 emsbaudrate:115200
bcdedit /ems on
bcdedit /bootems on
$emsCap = Get-WindowsCapability -Online -Name Windows.Desktop.EMS-SAC.Tools~~~~0.0.1.0
if ($emsCap.State -ne "Installed") {
    Add-WindowsCapability -Online -Name Windows.Desktop.EMS-SAC.Tools~~~~0.0.1.0
}

# --- TermService ---
Set-Service -Name TermService -StartupType Automatic
Start-Service TermService -ErrorAction SilentlyContinue

# --- Network profile ---
Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Private

# --- WinRM ---
Write-Output "Configuring WinRM..."
Enable-PSRemoting -Force -SkipNetworkProfileCheck 2>$null
# Enable-PSRemoting sets WinRM to Delayed Start; override to plain Automatic
# so the service is available immediately after reboot.
sc.exe config WinRM start= auto | Out-Null
Set-Item WSMan:\localhost\Service\AllowUnencrypted -Value True
Set-Item WSMan:\localhost\Service\Auth\Basic -Value True
$rule = Get-NetFirewallRule -Name winrm -ErrorAction SilentlyContinue
if (-not $rule) {
    New-NetFirewallRule -Name winrm -DisplayName 'WinRM HTTP' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 5985
}

# --- Hostname ---
if ((hostname) -ne "COCOON-VM") {
    Write-Output "Fixing hostname..."
    Rename-Computer -NewName 'COCOON-VM' -Force
}

# --- virtio-win guest tools ---
$vgt = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*" |
    Where-Object { $_.DisplayName -match 'Virtio-win' }
if (-not $vgt) {
    Write-Output "Installing virtio-win guest tools..."
    if (Test-Path D:\virtio-win-guest-tools.exe) {
        & D:\virtio-win-guest-tools.exe /S | Out-Null
    } elseif (Test-Path E:\virtio-win-guest-tools.exe) {
        & E:\virtio-win-guest-tools.exe /S | Out-Null
    } else {
        Write-Output "WARNING: virtio-win-guest-tools.exe not found on D: or E:"
    }
}

# --- ACPI power button = Shut down ---
# On Win11 25H2 the PBUTTONACTION setting is hidden by default (Attributes=1),
# so powercfg /setacvalueindex silently no-ops and verify.ps1's grep for
# "0x00000003" in `powercfg /query ... PBUTTONACTION` output finds nothing.
# Unhide the setting first, then set it.
powercfg /attributes 4f971e89-eebd-4455-a8de-9e59040e7347 7648efa3-dd9c-4e3e-b566-50f929386280 -ATTRIB_HIDE
powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS 7648efa3-dd9c-4e3e-b566-50f929386280 3
powercfg /setdcvalueindex SCHEME_CURRENT SUB_BUTTONS 7648efa3-dd9c-4e3e-b566-50f929386280 3
powercfg /setactive SCHEME_CURRENT

# --- Shutdown optimization ---
reg add "HKLM\SYSTEM\CurrentControlSet\Control" /v WaitToKillServiceTimeout /t REG_SZ /d 5000 /f
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v DisableShutdownNamedPipeCheck /t REG_DWORD /d 1 /f
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v shutdownwithoutlogon /t REG_DWORD /d 1 /f

# --- VM UI optimization ---
Write-Output "Applying VM UI optimizations..."
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" /v VisualFXSetting /t REG_DWORD /d 2 /f
reg add "HKCU\Control Panel\Desktop" /v UserPreferencesMask /t REG_BINARY /d 9012038010000000 /f
reg add "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize" /v EnableTransparency /t REG_DWORD /d 0 /f
reg add "HKCU\Control Panel\Desktop" /v MenuShowDelay /t REG_SZ /d 0 /f
Set-ItemProperty 'HKCU:\Control Panel\Desktop' -Name Wallpaper -Value ''

# --- High perf power plan ---
Write-Output "Setting High Performance power plan..."
powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c
powercfg /change monitor-timeout-ac 0
powercfg /change standby-timeout-ac 0

# --- Disable unnecessary services ---
Write-Output "Disabling SysMain and WSearch..."
Set-Service SysMain -StartupType Disabled -ErrorAction SilentlyContinue
Stop-Service SysMain -Force -ErrorAction SilentlyContinue
Set-Service WSearch -StartupType Disabled -ErrorAction SilentlyContinue
Stop-Service WSearch -Force -ErrorAction SilentlyContinue

# --- Disable bloat features ---
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\GameDVR" /v AllowGameDVR /t REG_DWORD /d 0 /f
reg add "HKLM\SOFTWARE\Policies\Microsoft\Dsh" /v AllowNewsAndInterests /t REG_DWORD /d 0 /f
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\Personalization" /v NoLockScreen /t REG_DWORD /d 1 /f

# --- Reduce background I/O ---
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection" /v AllowTelemetry /t REG_DWORD /d 0 /f
reg add "HKLM\SOFTWARE\Policies\Microsoft\WindowsStore" /v AutoDownload /t REG_DWORD /d 2 /f
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization" /v DODownloadMode /t REG_DWORD /d 0 /f

# --- Cortana / Copilot / tips ---
Write-Output "Disabling Cortana, Copilot, tips..."
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Search" /v AllowCortana /t REG_DWORD /d 0 /f
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot" /v TurnOffWindowsCopilot /t REG_DWORD /d 1 /f
reg add "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SubscribedContent-338389Enabled /t REG_DWORD /d 0 /f
reg add "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SubscribedContent-310093Enabled /t REG_DWORD /d 0 /f
reg add "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SilentInstalledAppsEnabled /t REG_DWORD /d 0 /f
reg add "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Serialize" /v StartupDelayInMSec /t REG_DWORD /d 0 /f

# --- DWM / window animations ---
Write-Output "Disabling DWM animations..."
reg add "HKCU\Control Panel\Desktop\WindowMetrics" /v MinAnimate /t REG_SZ /d 0 /f
reg add "HKCU\Control Panel\Desktop" /v DragFullWindows /t REG_SZ /d 0 /f
reg add "HKCU\Control Panel\Desktop" /v FontSmoothing /t REG_SZ /d 2 /f

# --- Disable scheduled tasks ---
Write-Output "Disabling unnecessary scheduled tasks..."
Disable-ScheduledTask -TaskName '\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser' -ErrorAction SilentlyContinue
Disable-ScheduledTask -TaskName '\Microsoft\Windows\Defrag\ScheduledDefrag' -ErrorAction SilentlyContinue
Disable-ScheduledTask -TaskName '\Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector' -ErrorAction SilentlyContinue

Write-Output "=== Remediation complete ==="
