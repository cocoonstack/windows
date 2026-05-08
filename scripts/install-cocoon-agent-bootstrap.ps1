# Bootstrap installer for cocoon-agent: download the pinned Windows release
# from GitHub, verify SHA256, extract, run the bundled installer.
#
# To bump the agent: update $version + $expected together (release page's
# checksums.txt has the canonical SHA256). The build script copies this file
# to the install ISO root; autounattend.xml Order 53 invokes it from there
# at firstboot. We also self-copy to C:\Scripts so remediate.ps1 can re-run
# us against an already-installed image.

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

$version  = '0.1.1'
$url      = "https://github.com/cocoonstack/cocoon-agent/releases/download/v$version/cocoon-agent_${version}_Windows_x86_64.zip"
$expected = 'eb91ac8f0c34f1076fd7c9b5d343c8250ca39c5bb8dd890977ed6574b3a5fdf0'
$zip      = Join-Path $env:TEMP "cocoon-agent_${version}_Windows_x86_64.zip"
$extract  = Join-Path $env:TEMP "cocoon-agent-${version}"

# Self-copy to C:\Scripts so remediate.ps1 (and ad-hoc re-runs) can find us
# without needing the install ISO mounted.
$scriptsDir = 'C:\Scripts'
$bootstrapDest = Join-Path $scriptsDir 'install-cocoon-agent-bootstrap.ps1'
if (-not (Test-Path $scriptsDir)) { New-Item -ItemType Directory -Path $scriptsDir | Out-Null }
if ($PSCommandPath -and (Test-Path $PSCommandPath) -and ((Resolve-Path $PSCommandPath).Path -ne (Resolve-Path -LiteralPath $bootstrapDest -ErrorAction SilentlyContinue).Path)) {
    Copy-Item -Path $PSCommandPath -Destination $bootstrapDest -Force
}

# DHCP/DNS can take a few seconds to settle at firstboot.
for ($i = 1; $i -le 5; $i++) {
    try { Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing; break }
    catch { if ($i -eq 5) { throw }; Start-Sleep -Seconds 5 }
}

$actual = (Get-FileHash -Path $zip -Algorithm SHA256).Hash.ToLower()
if ($actual -ne $expected) {
    throw "cocoon-agent zip checksum mismatch: expected $expected, got $actual"
}

if (Test-Path $extract) { Remove-Item -Recurse -Force $extract }
Expand-Archive -Path $zip -DestinationPath $extract -Force

# Locate by glob — zip puts exe at root and ps1 under packaging/.
$ps1 = Get-ChildItem -Path $extract -Recurse -Filter 'install-cocoon-agent.ps1' | Select-Object -First 1
$exe = Get-ChildItem -Path $extract -Recurse -Filter 'cocoon-agent.exe'         | Select-Object -First 1
if (-not $ps1) { throw "install-cocoon-agent.ps1 not found in $extract" }
if (-not $exe) { throw "cocoon-agent.exe not found in $extract" }

& $ps1.FullName -BinarySource $exe.FullName
