# Bootstrap installer for cocoon-agent: download the pinned Windows release
# from GitHub, verify SHA256, extract, run the bundled installer.
#
# To bump the agent: update $version + $expected together (release page's
# checksums.txt has the canonical SHA256). The matching base64 block in
# autounattend.xml Order 53 must be regenerated from this file in lockstep
# or images will silently ship the old version.

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

$version  = '0.1.1'
$url      = "https://github.com/cocoonstack/cocoon-agent/releases/download/v$version/cocoon-agent_${version}_Windows_x86_64.zip"
$expected = 'acd2e87c35947db4076f9fa1b91a3162f91061e5a863e75e5b032714efdc40ab'
$zip      = Join-Path $env:TEMP "cocoon-agent_${version}_Windows_x86_64.zip"
$extract  = Join-Path $env:TEMP "cocoon-agent-${version}"

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
