# Cycle a Net PnP device only when its default gateway is unreachable —
# the chained-clone NIC-bound-no-traffic state shows up as a failed ICMP
# to the gateway even though Get-PnpDevice still reports Status=OK. Skip
# adapters whose gateway answers; cycling a healthy NIC drops every host
# session through it (SSH, RDP, etc) for several seconds.
$ErrorActionPreference = "SilentlyContinue"
foreach ($adapter in (Get-NetAdapter | Where-Object Status -eq 'Up')) {
    $gw = (Get-NetRoute -InterfaceIndex $adapter.ifIndex -DestinationPrefix '0.0.0.0/0' | Select-Object -First 1).NextHop
    if (-not $gw -or $gw -eq '0.0.0.0') { continue }
    if (Test-Connection -ComputerName $gw -Count 1 -Quiet -TimeoutSeconds 2) { continue }
    $pnp = Get-PnpDevice -PresentOnly -Class Net | Where-Object InstanceId -eq $adapter.PnpDeviceID
    if (-not $pnp) { continue }
    Disable-PnpDevice -InstanceId $pnp.InstanceId -Confirm:$false
    Start-Sleep -Seconds 2
    Enable-PnpDevice -InstanceId $pnp.InstanceId -Confirm:$false
}
