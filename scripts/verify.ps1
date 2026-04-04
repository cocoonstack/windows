# verify.ps1 - Verify Windows VM post-install configuration
# Exit 0 if all checks pass, 1 if any fail

$ErrorActionPreference = "SilentlyContinue"
$failed = 0
$total = 0

function Check([string]$name, [bool]$result) {
    $script:total++
    if ($result) {
        Write-Output "PASS  $name"
    } else {
        Write-Output "FAIL  $name"
        $script:failed++
    }
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

# --- Hostname ---
Check "Hostname = COCOON-VM" ((hostname) -eq "COCOON-VM")

# --- VirtIO drivers ---
$vd = Get-WmiObject Win32_PnPSignedDriver | Where-Object { $_.DeviceName -match 'VirtIO' }
Check "VirtIO drivers (>=3)" ($vd.Count -ge 3)

# --- virtio-win guest tools ---
$vgt = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*" |
    Where-Object { $_.DisplayName -match 'Virtio-win' }
Check "virtio-win guest tools installed" ($null -ne $vgt)

# --- Install marker ---
Check "C:\install.success exists" (Test-Path C:\install.success)

# --- Summary ---
Write-Output ""
Write-Output "$($script:total - $script:failed)/$($script:total) checks passed"

if ($script:failed -gt 0) { exit 1 } else { exit 0 }
