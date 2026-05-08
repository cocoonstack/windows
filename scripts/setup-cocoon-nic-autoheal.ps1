# Stage cocoon-nic-autoheal.ps1 to C:\CocoonNicAutoHeal.ps1 and register the
# CocoonNicAutoHeal scheduled task. Idempotent — autounattend invokes us at
# firstboot from the install ISO; remediate.ps1 invokes us from C:\Scripts
# after first install when the schtask has gone missing. Both the source ps1
# and self get cached to C:\Scripts so the remediate path doesn't need the ISO.

$ErrorActionPreference = 'Stop'

$scriptsDir = 'C:\Scripts'
$cachedBody = Join-Path $scriptsDir 'cocoon-nic-autoheal.ps1'
$cachedSelf = Join-Path $scriptsDir 'setup-cocoon-nic-autoheal.ps1'

if (-not (Test-Path $scriptsDir)) { New-Item -ItemType Directory -Path $scriptsDir | Out-Null }

$src = $null
if (Test-Path $cachedBody) {
    $src = $cachedBody
} else {
    foreach ($d in @('D', 'E')) {
        $candidate = "${d}:\cocoon-nic-autoheal.ps1"
        if (Test-Path $candidate) { $src = $candidate; break }
    }
}
if (-not $src) { throw 'cocoon-nic-autoheal.ps1 not found on C:\Scripts or D:/E:' }

Copy-Item -Path $src -Destination 'C:\CocoonNicAutoHeal.ps1' -Force
if ($src -ne $cachedBody) { Copy-Item -Path $src -Destination $cachedBody -Force }

if ($PSCommandPath -and (Test-Path $PSCommandPath) -and ((Resolve-Path $PSCommandPath).Path -ne (Resolve-Path -LiteralPath $cachedSelf -ErrorAction SilentlyContinue).Path)) {
    Copy-Item -Path $PSCommandPath -Destination $cachedSelf -Force
}

schtasks /create /tn CocoonNicAutoHeal `
    /tr 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\CocoonNicAutoHeal.ps1' `
    /sc minute /mo 1 /ru SYSTEM /rl HIGHEST /f
