# verify.ps1 - Verify Windows VM post-install configuration
# Exit 0 if all checks pass, 1 if any fail

param(
    [switch]$RequireSerialDevice
)

$ErrorActionPreference = "SilentlyContinue"
$failed = 0
$total = 0
$warnings = 0

function Check([string]$name, [bool]$result) {
    $script:total++
    if ($result) {
        Write-Output "PASS  $name"
    } else {
        Write-Output "FAIL  $name"
        $script:failed++
    }
}

function Warn([string]$message) {
    $script:warnings++
    Write-Output "WARN  $message"
}

# --- Services ---
$sshd = Get-Service sshd
Check "sshd running"   ($sshd.Status -eq "Running")
Check "sshd automatic" ($sshd.StartType -eq "Automatic")

$ts = Get-Service TermService
Check "TermService running"   ($ts.Status -eq "Running")
Check "TermService automatic" ($ts.StartType -eq "Automatic")

$ga = Get-Service "QEMU-GA"
Check "QEMU-GA running"   ($ga.Status -eq "Running")
Check "QEMU-GA automatic" ($ga.StartType -eq "Automatic")

# --- RDP ---
$rdpVal = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server').fDenyTSConnections
Check "RDP enabled (fDenyTSConnections=0)" ($rdpVal -eq 0)

# --- SSH ---
$sshConn = Test-NetConnection -ComputerName localhost -Port 22 -WarningAction SilentlyContinue
Check "SSH port 22" ($sshConn.TcpTestSucceeded)

# --- WinRM ---
$winrmUn = (Get-Item WSMan:\localhost\Service\AllowUnencrypted).Value
Check "WinRM AllowUnencrypted" ($winrmUn -eq "true")

$winrmBasic = (Get-Item WSMan:\localhost\Service\Auth\Basic).Value
Check "WinRM Basic auth" ($winrmBasic -eq "true")

$winrmConn = Test-NetConnection -ComputerName localhost -Port 5985 -WarningAction SilentlyContinue
Check "WinRM port 5985" ($winrmConn.TcpTestSucceeded)

# --- SAC / EMS ---
$bcd = bcdedit /enum 2>&1 | Out-String
Check "EMS enabled"      ($bcd -match "ems\s+Yes")
Check "Boot EMS enabled" ($bcd -match "bootems\s+Yes")

Check "sacdrv.sys present" (Test-Path "$env:windir\System32\drivers\sacdrv.sys")
Check "sacsess.exe present" (Test-Path "$env:windir\System32\sacsess.exe")

$sacQc = sc.exe qc sacdrv 2>&1 | Out-String
Check "sacdrv registered" ($LASTEXITCODE -eq 0 -and $sacQc -match "SERVICE_NAME:\s+sacdrv")

$serialSvc = Get-Service Serial
Check "Serial service present" ($null -ne $serialSvc)
if ($null -ne $serialSvc) {
    Check "Serial service startup set" ($serialSvc.StartType -ne "Disabled")
}

$serialDev = Get-CimInstance Win32_PnPEntity | Where-Object {
    $_.PNPDeviceID -like 'ACPI\\PNP0501*' -and $_.Present
}
if ($RequireSerialDevice) {
    Write-Output "INFO  RequireSerialDevice is advisory; use sac_probe.py for the authoritative CH serial check"
}

if ($null -ne $serialDev) {
    Write-Output "INFO  COM1 PNP0501 present = True"
} else {
    Warn "COM1 PNP0501 present = False"
    Write-Output "INFO  Live SAC prompt detection is the authoritative CH serial signal"
}

# --- Firewall ---
$fwOn = (Get-NetFirewallProfile | Where-Object { $_.Enabled -eq $true }).Count
Check "Firewall all profiles off" ($fwOn -eq 0)

# --- Hibernate ---
$pwr = powercfg /a 2>&1 | Out-String
Check "Hibernate disabled" ($pwr -match "Hibernation has not been enabled")

# --- ACPI power button ---
$pb = powercfg /query SCHEME_CURRENT SUB_BUTTONS PBUTTONACTION 2>&1 | Out-String
Check "ACPI power button = shutdown (3)" ($pb -match "0x00000003")

# --- Shutdown optimization ---
$wtk = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control').WaitToKillServiceTimeout
Check "WaitToKillServiceTimeout = 5000" ($wtk -eq "5000")

$dsp = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System').DisableShutdownNamedPipeCheck
Check "DisableShutdownNamedPipeCheck = 1" ($dsp -eq 1)

$swl = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System').shutdownwithoutlogon
Check "shutdownwithoutlogon = 1" ($swl -eq 1)

# --- VM UI optimization ---
$vfx = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects').VisualFXSetting
Check "Visual effects = Best Performance (2)" ($vfx -eq 2)

$trans = (Get-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize').EnableTransparency
Check "Transparency disabled" ($trans -eq 0)

$menuDelay = (Get-ItemProperty 'HKCU:\Control Panel\Desktop').MenuShowDelay
Check "MenuShowDelay = 0" ($menuDelay -eq "0")

# --- High perf power plan ---
$activePlan = (powercfg /getactivescheme 2>&1 | Out-String)
Check "High Performance power plan" ($activePlan -match "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c")

# --- Unnecessary services disabled ---
$sysmain = Get-Service SysMain -ErrorAction SilentlyContinue
Check "SysMain disabled" ($null -eq $sysmain -or $sysmain.StartType -eq "Disabled")

$wsearch = Get-Service WSearch -ErrorAction SilentlyContinue
Check "WSearch disabled" ($null -eq $wsearch -or $wsearch.StartType -eq "Disabled")

# --- Bloat features disabled ---
$gameDvr = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' -ErrorAction SilentlyContinue).AllowGameDVR
Check "Game Bar/DVR disabled" ($gameDvr -eq 0)

$noLock = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization' -ErrorAction SilentlyContinue).NoLockScreen
Check "Lock screen disabled" ($noLock -eq 1)

# --- Background I/O reduction ---
$telemetry = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' -ErrorAction SilentlyContinue).AllowTelemetry
Check "Telemetry disabled" ($telemetry -eq 0)

$storeAuto = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore' -ErrorAction SilentlyContinue).AutoDownload
Check "Store auto-download disabled" ($storeAuto -eq 2)

$doMode = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' -ErrorAction SilentlyContinue).DODownloadMode
Check "Delivery Optimization off" ($doMode -eq 0)

# --- Cortana / Copilot / tips disabled ---
$cortana = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' -ErrorAction SilentlyContinue).AllowCortana
Check "Cortana disabled" ($cortana -eq 0)

$copilot = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' -ErrorAction SilentlyContinue).TurnOffWindowsCopilot
Check "Copilot disabled" ($copilot -eq 1)

$tips = (Get-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -ErrorAction SilentlyContinue).'SubscribedContent-338389Enabled'
Check "Tips/suggestions disabled" ($tips -eq 0)

$silentApps = (Get-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -ErrorAction SilentlyContinue).SilentInstalledAppsEnabled
Check "Silent app installs disabled" ($silentApps -eq 0)

$startupDelay = (Get-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Serialize' -ErrorAction SilentlyContinue).StartupDelayInMSec
Check "Startup delay = 0" ($startupDelay -eq 0)

# --- DWM / window animations ---
$minAnim = (Get-ItemProperty 'HKCU:\Control Panel\Desktop\WindowMetrics' -ErrorAction SilentlyContinue).MinAnimate
Check "Window minimize animation off" ($minAnim -eq "0")

$dragFull = (Get-ItemProperty 'HKCU:\Control Panel\Desktop' -ErrorAction SilentlyContinue).DragFullWindows
Check "Drag full windows off" ($dragFull -eq "0")

# --- Hostname ---
Check "Hostname = COCOON-VM" ((hostname) -eq "COCOON-VM")

# --- VirtIO drivers ---
# Minimum 2 (viostor + NetKVM); Balloon only present if host exposes virtio-balloon device
$vd = Get-WmiObject Win32_PnPSignedDriver | Where-Object { $_.DeviceName -match 'VirtIO' }
Check "VirtIO drivers (>=2)" ($vd.Count -ge 2)

# --- virtio-win guest tools ---
$vgt = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*" |
    Where-Object { $_.DisplayName -match 'Virtio-win' }
Check "virtio-win guest tools installed" ($null -ne $vgt)

# --- Install marker ---
Check "C:\install.success exists" (Test-Path C:\install.success)

# --- Summary ---
Write-Output ""
if ($script:warnings -gt 0) {
    Write-Output "$($script:total - $script:failed)/$($script:total) checks passed, $($script:warnings) warning(s)"
} else {
    Write-Output "$($script:total - $script:failed)/$($script:total) checks passed"
}

if ($script:failed -gt 0) { exit 1 } else { exit 0 }
