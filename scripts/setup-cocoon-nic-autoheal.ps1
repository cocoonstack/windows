# Copy cocoon-nic-autoheal.ps1 from the install ISO to C:\CocoonNicAutoHeal.ps1
# and register the CocoonNicAutoHeal scheduled task to run it every minute as
# SYSTEM. Invoked once at firstboot via autounattend.xml.

$ErrorActionPreference = 'Stop'

$src = $null
foreach ($d in @('D', 'E')) {
    $candidate = "${d}:\cocoon-nic-autoheal.ps1"
    if (Test-Path $candidate) { $src = $candidate; break }
}
if (-not $src) { throw 'cocoon-nic-autoheal.ps1 not found on D: or E:' }

Copy-Item -Path $src -Destination 'C:\CocoonNicAutoHeal.ps1' -Force

schtasks /create /tn CocoonNicAutoHeal `
    /tr 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\CocoonNicAutoHeal.ps1' `
    /sc minute /mo 1 /ru SYSTEM /rl HIGHEST /f
