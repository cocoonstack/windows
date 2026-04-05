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

# --- TermService ---
Set-Service -Name TermService -StartupType Automatic
Start-Service TermService -ErrorAction SilentlyContinue

# --- EMS-SAC tools (20min timeout; FoD download can hang) ---
$emsCap = Get-WindowsCapability -Online -Name "Windows.Desktop.EMS-SAC.Tools~~~~0.0.1.0"
if ($emsCap.State -ne 'Installed') {
    Write-Output "Installing EMS-SAC Tools (timeout 20min)..."
    $j = Start-Job { Add-WindowsCapability -Online -Name Windows.Desktop.EMS-SAC.Tools~~~~0.0.1.0 }
    if (Wait-Job $j -Timeout 1200) {
        Receive-Job $j | Out-Null
        Write-Output "EMS-SAC Tools installed"
    } else {
        Stop-Job $j
        Write-Output "WARNING: EMS-SAC Tools install timed out"
    }
    Remove-Job $j -Force
}

# --- Network profile ---
Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Private

# --- WinRM ---
Write-Output "Configuring WinRM..."
Enable-PSRemoting -Force -SkipNetworkProfileCheck 2>$null
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
powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS PBUTTONACTION 3
powercfg /setdcvalueindex SCHEME_CURRENT SUB_BUTTONS PBUTTONACTION 3
powercfg /setactive SCHEME_CURRENT

# --- Shutdown optimization ---
reg add "HKLM\SYSTEM\CurrentControlSet\Control" /v WaitToKillServiceTimeout /t REG_SZ /d 5000 /f
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v DisableShutdownNamedPipeCheck /t REG_DWORD /d 1 /f
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v shutdownwithoutlogon /t REG_DWORD /d 1 /f

Write-Output "=== Remediation complete ==="
