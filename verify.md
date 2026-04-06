# Build Verification Notes (2026-04-06)

This document records the manual build verification performed on a no-internet test server,
the issues discovered, and the fixes applied. It is intended as a handoff so that a fresh
operator (human or AI) can reproduce or continue the work.

## Test server

| Item | Value |
|------|-------|
| OS | Ubuntu 24.04.4 LTS, kernel 6.8 |
| CPU | 192 vCPUs (vmx), KVM enabled |
| RAM | 377 GiB |
| Disk | 3.3 TiB free |
| QEMU | 10.2.1 (from /usr/local/bin) |
| Network | **No outbound internet** — all external TCP must be proxied |

### SSH note

The server's `sshd_config` had `DisableForwarding yes` at line 145. This was changed to
`DisableForwarding no` and sshd reloaded to allow SSH reverse tunnels. Without this,
`ssh -R` fails with "Server has disabled port forwarding."

### Installed packages

All build prerequisites were installed via `apt-get install`:

```
qemu-system-x86 qemu-utils ovmf swtpm mtools xorriso
openssh-client sshpass netcat-openbsd imagemagick
dnsmasq socat freerdp2-x11 redsocks
```

The system dnsmasq service was disabled (`systemctl disable dnsmasq`) to avoid conflicts
with the build/verify scripts that manage their own dnsmasq instances.

## Transparent proxy (required for no-internet hosts)

Because the test server cannot reach the internet directly (TCP connections to external
hosts time out; DNS resolves fine), a transparent proxy chain was set up:

```
Guest (QEMU slirp) -> Host TCP -> iptables -> redsocks -> SOCKS5 -> SSH tunnel -> Mac -> Internet
```

### Setup steps

**1. SSH reverse SOCKS proxy (from your Mac):**

```bash
sshpass -p 'Rj#@3VSDhtaphqQu' ssh -R 1080 -N -f \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 \
  root@10.104.192.181
```

This creates a SOCKS5 proxy at `127.0.0.1:1080` on the remote host, tunneled through
the Mac's internet connection.

**2. redsocks (on remote host):**

```bash
cat > /etc/redsocks.conf <<EOF
base { log_debug = off; log_info = on; daemon = on; redirector = iptables; }
redsocks { local_ip = 127.0.0.1; local_port = 12345; ip = 127.0.0.1; port = 1080; type = socks5; }
EOF
redsocks -c /etc/redsocks.conf
```

**3. iptables (on remote host):**

```bash
iptables -t nat -N REDSOCKS
iptables -t nat -A REDSOCKS -d 0.0.0.0/8 -j RETURN
iptables -t nat -A REDSOCKS -d 10.0.0.0/8 -j RETURN
iptables -t nat -A REDSOCKS -d 127.0.0.0/8 -j RETURN
iptables -t nat -A REDSOCKS -d 169.254.0.0/16 -j RETURN
iptables -t nat -A REDSOCKS -d 172.16.0.0/12 -j RETURN
iptables -t nat -A REDSOCKS -d 192.168.0.0/16 -j RETURN
iptables -t nat -A REDSOCKS -d 224.0.0.0/4 -j RETURN
iptables -t nat -A REDSOCKS -p tcp -j REDIRECT --to-ports 12345
iptables -t nat -A OUTPUT -p tcp -j REDSOCKS
```

**Verify:** `curl -s --connect-timeout 10 -o /dev/null -w '%{http_code}' https://github.com` should return `200`.

**Teardown:**

```bash
iptables -t nat -D OUTPUT -p tcp -j REDSOCKS
iptables -t nat -F REDSOCKS && iptables -t nat -X REDSOCKS
pkill redsocks
```

### Important caveats

- The SSH tunnel **must stay alive** for the entire build. If it drops, the QEMU guest
  loses internet and FoD installs (`Add-WindowsCapability -Online`) will hang or fail.
  Use `ServerAliveInterval=15` to keep it alive.
- The iptables rules redirect ALL outbound TCP (except private ranges) through the proxy.
  This includes QEMU's slirp user-mode networking, which is how the Windows guest reaches
  the internet.
- When done, **remove the iptables rules** before doing bridge/tap networking for
  Cloud Hypervisor verification — the transparent proxy interferes with `ip link` commands
  and can kill SSH sessions.

## Build execution

### Pre-place ISOs (saves re-downloading 8G over the tunnel)

```bash
mkdir -p /root/windows-build/work/qemu-build
scp Win11_25H2_EnglishInternational_x64_v2.iso root@10.104.192.181:/root/windows-build/work/qemu-build/windows-orig.iso
scp virtio-win-0.1.285.iso root@10.104.192.181:/root/windows-build/work/qemu-build/virtio-win.iso
```

The build script checks `if [[ ! -f "$WORKDIR/windows-orig.iso" ]]` before downloading,
so pre-placed files are reused automatically. **Do not delete the ISOs between runs.**

### Upload repo files and run

```bash
scp -r autounattend.xml scripts root@10.104.192.181:/root/windows-build/
# Optional: patch VNC for remote viewing (not committed to repo)
ssh root@10.104.192.181 "sed -i 's|-vnc 127.0.0.1:0|-vnc 0.0.0.0:0|' /root/windows-build/scripts/build-qemu.sh"
# Run
ssh root@10.104.192.181 "nohup bash -c 'cd /root/windows-build && chmod +x scripts/build-qemu.sh && WINDOWS_ISO_URL=dummy ./scripts/build-qemu.sh' > /root/windows-build/build.log 2>&1 &"
```

`WINDOWS_ISO_URL=dummy` satisfies the `${WINDOWS_ISO_URL:?}` check but the actual
download is skipped because the file already exists.

### Monitoring

```bash
# Build log milestones
grep -a '\[build-qemu\]' /root/windows-build/build.log | tail -5
# Disk growth
du -sh /root/windows-build/work/qemu-build/windows-11-25h2.qcow2
# Rolling screenshot (updated every 60s)
scp root@10.104.192.181:/root/windows-build/work/qemu-build/artifacts/qemu-progress.png .
# SSH into guest (after OpenSSH FoD installed, ~20-40 min in)
sshpass -p 'C@c#on160' ssh -p 2222 cocoon@10.104.192.181
```

## Issues found and fixes applied

### 1. WinRM Delayed Start (verify failure)

**Symptom:** `verify.ps1` reports FAIL on WinRM AllowUnencrypted, Basic auth, and port 5985
after every reboot. `remediate.ps1` re-applies settings but they are lost again on next reboot.

**Root cause:** `Enable-PSRemoting -Force` sets WinRM service to `Automatic (Delayed Start)`.
After reboot, the service starts late and is not yet running when `verify.ps1` checks.

**Fix:**
- `autounattend.xml` Order 16: added `sc.exe config WinRM start= auto` after `Enable-PSRemoting`
- `remediate.ps1`: same `sc.exe config WinRM start= auto` after `Enable-PSRemoting`

**Verified:** After reboot, `sc qc WinRM` shows `AUTO_START` (not DELAYED), service is RUNNING,
port 5985 is listening.

### 2. EMS-SAC FoD Staged but not Installed (settle timeout)

**Symptom:** `wait_for_firstboot_settle` sees `sacdrv=False sacsess=False registered=False
servicing=0` indefinitely. The FoD reaches `Staged` or `InstallPending` state but never
finalizes because it needs an additional reboot that the build script doesn't trigger.

**Root cause:** `Add-WindowsCapability -Online` for a satellite FoD (like EMS-SAC) may
only stage the package. A reboot is required to move from Staged -> Installed, which
drops the actual files (`sacdrv.sys`, `sacsess.exe`) and registers the service.

**Fix:** Modified `wait_for_firstboot_settle()` in `build-qemu.sh` to detect the stale
state (servicing=0 but sacdrv=False for 3+ consecutive probes) and automatically trigger
a guest reboot, then continue waiting.

**Verified:** Build completes with `sacdrv=True sacsess=True registered=True` after the
auto-reboot.

### 3. QuickEdit console freeze via VNC

**Symptom:** PowerShell progress bar ("Operation Running [ooo...]") completes but the
console appears frozen. Pressing Enter in the VNC viewer unfreezes it.

**Root cause:** QEMU's `-device usb-tablet` sends absolute mouse positioning events. When
a VNC client is connected and the cursor is over a console window, Windows Console's
QuickEdit mode interprets mouse events as text selection ("Mark mode"), freezing all output.

**Fix:**
- `autounattend.xml` Order 1: `reg add "HKCU\Console" /v QuickEdit /t REG_DWORD /d 0 /f`
- `autounattend.xml` Order 29: restores QuickEdit to 1 after all commands are done

### 4. FoD output causes console pagination

**Symptom:** `Add-WindowsCapability` outputs a result object (`RestartNeeded: True`) that
can cause the console to pause for user input.

**Fix:** Added `| Out-Null` to both `Add-WindowsCapability` calls in `autounattend.xml`
(Order 4 for OpenSSH, Order 13 for EMS-SAC).

### 5. WU cumulative updates block FoD download (not fully resolved)

**Symptom:** `Add-WindowsCapability -Online` triggers Windows Update, which discovers
pending cumulative updates (~2 GB) and downloads them before processing the tiny FoD
(374 KB for EMS-SAC, 5.6 MB for OpenSSH). This adds 20-40 minutes on slow connections.

**Attempted fixes that did NOT work (Win11 25H2 Tamper Protection blocks them):**
- `reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v NoAutoUpdate` — ignored at runtime
- `reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows Defender" /v DisableAntiSpyware` — ignored at runtime
- `Set-MpPreference -DisableRealtimeMonitoring $true` — works from elevated PS but resets
- `net stop WinDefend` — Access denied (Tamper Protection)

**Current state:** These registry-based approaches were removed from the committed code
because they are ineffective. On GitHub Actions (ubuntu-latest), direct internet is fast
enough that the CU download doesn't cause significant delay. On slow/proxied connections,
FoD installation takes 20-40 minutes due to WU background activity.

## Cloud Hypervisor verification

After the qcow2 is built, verify it boots correctly on Cloud Hypervisor:

### Prerequisites

```bash
# Download cocoonstack CH fork + firmware
curl -fsSL -o /usr/local/bin/cloud-hypervisor \
  https://github.com/cocoonstack/cloud-hypervisor/releases/download/dev/cloud-hypervisor
chmod +x /usr/local/bin/cloud-hypervisor
mkdir -p /usr/local/share/cloud-hypervisor
curl -fsSL -o /usr/local/share/cloud-hypervisor/CLOUDHV.fd \
  https://github.com/cocoonstack/rust-hypervisor-firmware/releases/download/dev/hypervisor-fw
```

### Remove transparent proxy first

The iptables rules from the build phase interfere with bridge networking. Clean them up:

```bash
iptables -t nat -D OUTPUT -p tcp -j REDSOCKS 2>/dev/null
iptables -t nat -F REDSOCKS 2>/dev/null && iptables -t nat -X REDSOCKS 2>/dev/null
pkill redsocks 2>/dev/null
```

### Run verification

Use the repo's `scripts/verify-ch.sh`:

```bash
QCOW2_PATH=/root/windows-build/work/qemu-build/windows-11-25h2.qcow2 \
  ./scripts/verify-ch.sh
```

Or manually:

```bash
# Bridge + TAP + dnsmasq
ip link add br-ch type bridge
ip addr add 192.168.100.1/24 dev br-ch && ip link set br-ch up
ip tuntap add tap-ch mode tap user root
ip link set tap-ch master br-ch && ip link set tap-ch up
dnsmasq --interface=br-ch --bind-interfaces \
  --dhcp-range=192.168.100.100,192.168.100.200,12h \
  --dhcp-option=option:router,192.168.100.1 \
  --dhcp-option=option:dns-server,8.8.8.8 --port=0

# Launch CH
cloud-hypervisor \
  --firmware /usr/local/share/cloud-hypervisor/CLOUDHV.fd \
  --disk path=windows-11-25h2.qcow2,image_type=qcow2,backing_files=on \
  --cpus boot=4,kvm_hyperv=on --memory size=8G \
  --net tap=tap-ch,mac=52:54:00:dc:7f:ba \
  --rng src=/dev/urandom \
  --serial socket=/tmp/ch-serial.sock --console off &
```

### Expected results

| Check | Expected |
|-------|----------|
| DHCP lease | Guest gets IP from 192.168.100.100-200 range, hostname `COCOON-VM` |
| Ping | `ping <guest-ip>` — 0% loss |
| SAC prompt | Connect to serial socket, send `\r\n`, receive `SAC>` |
| SAC `i` command | Shows `Ip=192.168.100.x Subnet=255.255.255.0 Gateway=192.168.100.1` |
| SSH | `sshpass -p 'C@c#on160' ssh cocoon@<guest-ip>` — gets CMD shell |
| RDP | `xfreerdp /v:<guest-ip> /u:cocoon /p:'C@c#on160' /auth-only /cert:ignore` — auth succeeds |

### Verification results (2026-04-06)

All checks passed on CH v51 + cocoonstack firmware:

```
DHCP: 192.168.100.169, hostname COCOON-VM
Ping: 4/4 received, 0% loss
SAC: SAC> prompt detected
SAC i: Ip=192.168.100.169 Subnet=255.255.255.0 Gateway=192.168.100.1
```

## GitHub Actions

The workflow is at `.github/workflows/build.yml`, triggered via `workflow_dispatch`:

```bash
gh workflow run build.yml --repo CMGS/windows -f version_tag=win11-25h2
```

Requires repo secret `WINDOWS_ISO_URL` set to a valid Microsoft signed download URL.
The URL expires periodically and must be refreshed.

```bash
gh secret set WINDOWS_ISO_URL --repo CMGS/windows --body '<url>'
```

Last failure (run 23993959517) failed with the same two bugs fixed in this commit:
EMS-SAC not installed + WinRM Delayed Start.

## Summary of changes in commit `0668244`

| File | Change |
|------|--------|
| `autounattend.xml` | QuickEdit disable/restore, `\| Out-Null` on FoD installs, `sc.exe config WinRM start= auto`, reordered to 30 commands |
| `scripts/build-qemu.sh` | settle function auto-reboots when FoD is Staged (servicing=0 + sacdrv=False for 3+ probes) |
| `scripts/remediate.ps1` | `sc.exe config WinRM start= auto` after `Enable-PSRemoting` |
