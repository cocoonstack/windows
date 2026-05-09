# Cycle only the Present Net PnP devices whose specific default-route
# gateway is unreachable. The chained-clone NIC-bound-no-traffic state
# inherits a stale gateway in the route table; ICMP via that adapter
# silently fails. Per-adapter probe + per-adapter cycle, so healthy
# NICs aren't bounced (which would drop SSH/RDP sessions through them).
$ErrorActionPreference = "SilentlyContinue"
$ping = New-Object System.Net.NetworkInformation.Ping
$pnpByPnpId = @{}
foreach ($p in (Get-PnpDevice -Class Net -PresentOnly)) { $pnpByPnpId[$p.InstanceId] = $p }
$adapters = Get-NetAdapter | Where-Object { $_.PnPDeviceID -and $pnpByPnpId.ContainsKey($_.PnPDeviceID) }
$anyHealthy = $false
$toCycle = @()
foreach ($a in $adapters) {
    $gw = (Get-NetRoute -InterfaceIndex $a.ifIndex -DestinationPrefix '0.0.0.0/0' -EA SilentlyContinue |
        Select-Object -First 1).NextHop
    if (-not $gw -or $gw -eq '0.0.0.0') { continue }
    $opts = New-Object System.Net.NetworkInformation.PingOptions
    $reply = $ping.Send($gw, 2000, [byte[]](1), $opts)
    if ($reply -and $reply.Status -eq 'Success') {
        $anyHealthy = $true
    } else {
        $toCycle += $pnpByPnpId[$a.PnPDeviceID]
    }
}
# Adapters with no default route at all (route table empty post-restore).
# Only blanket-cycle when no other adapter is currently healthy — otherwise
# leave the working one alone.
if (-not $anyHealthy -and $toCycle.Count -eq 0) {
    $toCycle = $pnpByPnpId.Values
}
# Pipe the batch through cmdlet once each — matches the cocoon clone hint
# form. PnP cmdlets process the batch concurrently, avoiding the per-device
# disable/sleep/enable serialization in older revisions of this script.
if ($toCycle.Count -gt 0) {
    $toCycle | Disable-PnpDevice -Confirm:$false
    $toCycle | Enable-PnpDevice -Confirm:$false
}
