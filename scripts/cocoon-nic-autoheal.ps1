# If no default-route gateway answers ICMP, cycle every Present Net PnP
# device. The chained-clone failure mode often leaves the route table
# empty entirely, so a per-adapter Status check misses it. Skipping the
# cycle when any gateway answers preserves SSH/RDP sessions on healthy
# guests (the 1-min schtasks cadence would otherwise blip them).
$ErrorActionPreference = "SilentlyContinue"
$ping = New-Object System.Net.NetworkInformation.Ping
$gateways = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -EA SilentlyContinue |
    Where-Object NextHop -ne '0.0.0.0').NextHop | Sort-Object -Unique
$healthy = $false
foreach ($gw in $gateways) {
    $reply = $ping.Send($gw, 2000)
    if ($reply -and $reply.Status -eq 'Success') { $healthy = $true; break }
}
if ($healthy) { return }
foreach ($d in (Get-PnpDevice -Class Net -PresentOnly)) {
    Disable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false
    Start-Sleep -Seconds 2
    Enable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false
}
