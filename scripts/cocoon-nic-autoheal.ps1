# cocoon-nic-autoheal.ps1 — cycle every Net-class PnP device once.
#
# Triggered by the CocoonNicAutoHeal scheduled task (registered at firstboot)
# on a 1-minute repeat. Recovers chained-clone Win11 guests where vm.restore
# leaves the NIC bound at the OS layer but unable to transmit — Status reports
# 'OK' so a "Status -EQ Error" filter would miss it. Cycle unconditionally.
$ErrorActionPreference = "SilentlyContinue"
foreach ($d in (Get-PnpDevice -Class Net)) {
    Disable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false
    Start-Sleep -Seconds 2
    Enable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false
}
