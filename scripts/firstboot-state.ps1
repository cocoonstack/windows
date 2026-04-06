# firstboot-state.ps1 - Emit concrete first-boot SAC readiness signals.
# Exit code is always 0; callers should inspect the key=value output.

$ErrorActionPreference = "SilentlyContinue"

$sacQc = sc.exe qc sacdrv 2>&1 | Out-String
$serialDev = Get-CimInstance Win32_PnPEntity | Where-Object {
    $_.PNPDeviceID -like 'ACPI\\PNP0501*' -and $_.Present
}
$servicing = @(Get-Process dism,TiWorker -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)

Write-Output "INSTALL_SUCCESS_PRESENT=$([bool](Test-Path C:\install.success))"
Write-Output "SACDRV_PRESENT=$([bool](Test-Path "$env:windir\System32\drivers\sacdrv.sys"))"
Write-Output "SACSESS_PRESENT=$([bool](Test-Path "$env:windir\System32\sacsess.exe"))"
Write-Output "SACDRV_REGISTERED=$([bool]($LASTEXITCODE -eq 0 -and $sacQc -match 'SERVICE_NAME:\s+sacdrv'))"
Write-Output "SERIAL_DEVICE_PRESENT=$([bool]($null -ne $serialDev))"
Write-Output "SERVICING_PROCESS_COUNT=$($servicing.Count)"
Write-Output "SERVICING_PROCESS_NAMES=$($servicing -join ',')"
