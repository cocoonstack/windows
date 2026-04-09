# Windows VM Image

Build automation for Windows 11 25H2 disk images targeting Cloud Hypervisor.
The design goal is that a fresh Linux host can build and validate a Cocoon-compatible
Windows image using this repository alone plus a Windows ISO download URL.

Contents:

- `autounattend.xml` — unattended Windows setup configuration
- `scripts/build-qemu.sh` — reproducible local QEMU build, with one rolling screenshot file and a bounded first-boot settle loop
- `scripts/verify.ps1` + `scripts/remediate.ps1` — in-guest verification / remediation loop
- `scripts/firstboot-state.ps1` — lightweight first-boot probe used to wait for concrete SAC runtime components before verification
- `scripts/verify-ch.sh` + `scripts/sac_probe.py` — Cloud Hypervisor runtime validation for DHCP, RDP, real SAC, and clean shutdown
- `.github/workflows/build.yml` — headless QEMU/KVM build on `ubuntu-latest`, publishes to GHCR via ORAS

## Acceptance Criteria

An image produced from this repo is only considered valid for Cocoon if all of these are true:

- It boots on `cloud-hypervisor` with `CLOUDHV.fd`.
- It acquires a DHCP lease from a plain `dnsmasq` bridge and reports hostname `COCOON-VM`.
- `3389/tcp` accepts a real RDP authentication attempt.
- `COM1` exposes a real SAC console after Cloud Hypervisor boot. A live `SAC>` prompt is the hard requirement; missing in-guest `ACPI\\PNP0501` enumeration is only a warning. `bcdedit /ems on` by itself is **not** sufficient.
- A remote `shutdown /s /t 10` cleanly terminates the Cloud Hypervisor process.

## Pulling a pre-built image

Built images are published as OCI artifacts to GHCR:

```
ghcr.io/cocoonstack/windows/win11:25h2              # moving alias, latest good build
ghcr.io/cocoonstack/windows/win11:25h2-<YYYYMMDD>   # dated immutable tag
```

### 1. Pull

```bash
# Requires oras CLI -- https://oras.land
oras pull ghcr.io/cocoonstack/windows/win11:25h2
```

This drops the split parts and `SHA256SUMS` into the current directory:

```
windows-11-25h2.qcow2.00.qcow2.part    1.9G
windows-11-25h2.qcow2.01.qcow2.part    1.9G
...
windows-11-25h2.qcow2.07.qcow2.part    ~200M
SHA256SUMS
```

### 2. Reassemble into a qcow2

The qcow2 is split into ~1.9 GiB parts so every blob stays under the GHCR per-layer limit. `split` produces chunks in lexicographic order, so a plain `cat` with a glob gives you the original file back byte-for-byte:

```bash
cat windows-11-25h2.qcow2.*.qcow2.part > windows-11-25h2.qcow2
sha256sum -c SHA256SUMS
rm windows-11-25h2.qcow2.*.qcow2.part   # optional, ~14 GiB of duplicate data
```

The OCI manifest also carries the reassemble command in the `cocoonstack.windows.reassemble` annotation so any tool inspecting the artifact can discover it.

### 3. Boot it on Cloud Hypervisor

```bash
qemu-img info windows-11-25h2.qcow2   # sanity check

# Install the patched fork binaries first (see "Version requirements" below).
cloud-hypervisor \
  --api-socket /tmp/ch.sock \
  --firmware /usr/local/share/cloud-hypervisor/CLOUDHV.fd \
  --disk path=windows-11-25h2.qcow2,image_type=qcow2,backing_files=on \
  --cpus boot=4,kvm_hyperv=on \
  --memory size=4G \
  --net tap=<tapname>,mac=52:54:00:xx:xx:xx \
  --rng src=/dev/urandom \
  --serial socket=/tmp/ch-serial.sock \
  --console off &
```

Login is the local admin `cocoon` account set up by `autounattend.xml`. SSH and WinRM are enabled out of the box. The guest picks up its IP from whichever DHCP server is listening on the bridge the tap is attached to.

Minimal host-side bridge + DHCP for a standalone test (not Cocoon-managed):

```bash
# bridge + dnsmasq (one-shot test harness)
sudo ip link add br-ch type bridge 2>/dev/null
sudo ip addr add 192.168.100.1/24 dev br-ch
sudo ip link set br-ch up
sudo ip tuntap add tap-ch mode tap user $USER 2>/dev/null
sudo ip link set tap-ch master br-ch
sudo dnsmasq --interface=br-ch --bind-interfaces \
  --dhcp-range=192.168.100.100,192.168.100.200,12h \
  --dhcp-option=option:router,192.168.100.1 \
  --dhcp-option=option:dns-server,8.8.8.8
```

Then launch `cloud-hypervisor --net tap=tap-ch,...` as above. After ~40 seconds the guest requests DHCP; watch `dnsmasq`'s log for the lease and `ssh cocoon@<leased-ip>` to get a CMD shell.

## Building yourself

Two flows share the same automation: **GitHub Actions** (`ubuntu-latest`, free tier, ~2 h, auto-publishes to GHCR) and **local** (any Linux + KVM host).

### Recommended local flow

If you want the supported path with the same checks Cocoon cares about, use the repo scripts directly:

```bash
QEMU_CPU_COUNT=16 QEMU_MEMORY=32G \
WINDOWS_ISO_URL='<signed Microsoft ISO URL>' ./scripts/build-qemu.sh

CH_CPU_COUNT=8 CH_MEMORY_SIZE=16G \
QCOW2_PATH="$(cat work/qemu-build/artifacts/qcow2.path)" \
  ./scripts/verify-ch.sh
```

CPU and memory overrides are optional. The defaults stay at `4` vCPU and `8G`
for both scripts, and you can raise them with `QEMU_CPU_COUNT`,
`QEMU_MEMORY`, `CH_CPU_COUNT`, and `CH_MEMORY_SIZE` when the host has spare
capacity.

`build-qemu.sh` keeps exactly one rolling screenshot at
`work/qemu-build/artifacts/qemu-progress.png`; it overwrites the same file during
install instead of generating numbered screenshots. After the planned first reboot,
it waits for `sacdrv.sys`, `sacsess.exe`, and `sacdrv` service registration to
appear with no active `dism` / `TiWorker` process before it runs `verify.ps1`.
That reboot can take well over 10 minutes while Windows finalizes servicing, so the
script intentionally gives SSH a long recovery window instead of treating a black
screen as an immediate failure.

### Version requirements

| Component        | Version      | Notes                                                                        |
|------------------|--------------|------------------------------------------------------------------------------|
| Cloud Hypervisor | **v51+**     | Use [cocoonstack/cloud-hypervisor `dev`][ch-fork] for full Windows support   |
| Firmware         | **patched**  | Use [cocoonstack/rust-hypervisor-firmware `dev`][fw-fork] for ACPI shutdown  |
| virtio-win       | **0.1.285**  | Latest stable; the patched CH fork's ctrl_queue + used_len fixes make 0.1.285 work on CH |
| QEMU (build)     | **≥ 8.x**    | Build host only — production runs on Cloud Hypervisor                        |
| xorriso (build)  | **any**      | Required to repack the Windows ISO; legacy `mkisofs` can't handle >4 GiB `install.wim` |
| OVMF (build)     | **secboot**  | `OVMF_CODE_4M.secboot.fd` — Win11 requires Secure Boot                       |

With our [CH fork][ch-fork] and [firmware fork][fw-fork], the known Windows issues on Cloud Hypervisor are resolved:
- v51 BSOD fixed ([#7849][ch-7849], [PR #7936][ch-7936])
- virtio-win 0.1.285 works ([#7925][ch-7925], ctrl_queue + used_len fix)
- ACPI power-button shutdown works ([firmware#422][fw-422], [firmware PR #423][fw-423])

Install patched binaries:

```bash
curl -fsSL -o /usr/local/bin/cloud-hypervisor \
  https://github.com/cocoonstack/cloud-hypervisor/releases/download/dev/cloud-hypervisor
chmod +x /usr/local/bin/cloud-hypervisor

curl -fsSL -o /usr/local/share/cloud-hypervisor/CLOUDHV.fd \
  https://github.com/cocoonstack/rust-hypervisor-firmware/releases/download/dev/hypervisor-fw
```

[ch-fork]: https://github.com/cocoonstack/cloud-hypervisor/tree/dev
[fw-fork]: https://github.com/cocoonstack/rust-hypervisor-firmware/tree/dev
[ch-7849]: https://github.com/cloud-hypervisor/cloud-hypervisor/issues/7849
[ch-7925]: https://github.com/cloud-hypervisor/cloud-hypervisor/issues/7925
[ch-7936]: https://github.com/cloud-hypervisor/cloud-hypervisor/pull/7936
[fw-422]: https://github.com/cloud-hypervisor/rust-hypervisor-firmware/issues/422
[fw-423]: https://github.com/cloud-hypervisor/rust-hypervisor-firmware/pull/423

### Building via GitHub Actions

```bash
gh workflow run build.yml --repo cocoonstack/windows -f image_name=win11 -f version_tag=25h2
```

Requires one repository secret:

- `WINDOWS_ISO_URL` — signed download URL for the Windows 11 25H2 ISO. Microsoft licensing prohibits bundling the ISO in the repo or any artifact, so fetch it at build time.

The workflow still only asks for `version_tag` and `disk_size`; it uses the
script defaults for guest CPU and memory because those overrides are not exposed
as workflow inputs.

The workflow:

1. Frees ~30 GiB of preinstalled SDKs from the runner (default ubuntu-latest has ~14 GiB free, not enough for the original ISO + repacked ISO + virtio-win + growing qcow2)
2. Repacks the Windows ISO with `autounattend.xml` injected at the ISO root and `efisys_noprompt.bin` as the EFI boot image (see "Why we repack" below)
3. Boots QEMU with Secure Boot OVMF + swtpm TPM 2.0 and the repacked ISO attached
4. Polls SSH for the `C:\install.success` marker (with a stall-detect + QMP `system_reset` fallback if the Phase 1 → Phase 2 reboot hangs)
5. Reboots the VM once, waits for `firstboot-state.ps1` to report concrete SAC runtime readiness, then runs `verify.ps1` and applies `remediate.ps1` on failure (up to 3 attempts)
6. Shuts the VM down cleanly, compresses the qcow2, splits it, and pushes to GHCR via ORAS

### Why we repack the ISO

Two independent Windows-on-QEMU hazards go away when the autounattend file lives on the install media at the root and the EFI boot image is the `_noprompt` variant:

1. **Win11 24H2+ modernized SetupHost skips the language/keyboard pickers only if it finds `autounattend.xml` on the install media itself.** Delivering the unattend file on a separate removable CD, floppy, or any other "second medium" is too late — the modernized UI renders the "Select language settings" + "Select keyboard settings" screens *before* SetupHost scans removable media for unattend. Pinning the file at the root of the install ISO (plus setting `<SetupUILanguage>` + `<UILanguage>` in the `Microsoft-Windows-International-Core-WinPE` component) is what actually tells SetupHost it's in unattended mode; it then skips the pickers and goes straight to partitioning.
2. **Every Windows UEFI install ISO ships two EFI boot images side by side: `efi/microsoft/boot/efisys.bin` (default) and `efi/microsoft/boot/efisys_noprompt.bin`.** The default variant makes `bootmgfw.efi` render the "Press any key to boot from CD" prompt and time out after ~5 seconds if you don't press anything. The `_noprompt` variant skips the prompt and boots immediately. Microsoft ships both on every Windows ISO specifically for automated deployment scenarios. Picking the `_noprompt` variant at `mkisofs` time removes the need to spray Enter keys through the QEMU monitor.

The repack itself is a one-liner with `xorriso`:

```bash
sudo mount -o loop,ro windows-orig.iso /mnt
cp -a /mnt/. iso_src/
sudo umount /mnt
chmod -R u+w iso_src
cp autounattend.xml iso_src/autounattend.xml      # at the root
xorriso -as mkisofs \
  -iso-level 3 \
  -J -joliet-long -R \
  -V "WIN11_25H2_UA" \
  -b boot/etfsboot.com -no-emul-boot -boot-load-size 8 -boot-info-table \
  -eltorito-alt-boot \
  -e efi/microsoft/boot/efisys_noprompt.bin -no-emul-boot \
  -o windows.iso \
  iso_src/
```

`-iso-level 3` is required because `sources/install.wim` is >4 GiB on modern Windows ISOs — legacy `mkisofs` can't pack it, `xorriso -as mkisofs` can.

### Building locally

#### Prerequisites

```bash
sudo apt-get install -y \
  qemu-system-x86 qemu-utils \
  ovmf swtpm mtools xorriso \
  openssh-client sshpass netcat-openbsd \
  imagemagick dnsmasq socat freerdp2-x11
```

Plus a Windows 11 25H2 ISO and [virtio-win-0.1.285.iso](https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.285-1/).

#### Quirks worth knowing upfront

These are the things that took a while to figure out. All of them are encoded into `build.yml`.

**1. q35 `-cdrom` shorthand can't coexist with a second `-drive ...,media=cdrom` on the same bus.** Use an explicit `-device ide-cd,drive=cd0,bus=ide.0` per CD, with one `ide.N` per unit. Don't mix shorthand and explicit.

**2. q35's floppy controller is not enumerated by Windows PE.** The classic "deliver autounattend.xml on a FAT floppy" trick fails silently. Use the ISO-repack approach described above instead of a sidecar floppy or CD.

**3. Windows 11 25H2 refuses to install without Secure Boot.** If you use `OVMF_CODE_4M.fd` (non-secboot), the installer reads autounattend.xml, starts Setup, and then immediately aborts with *"This PC doesn't currently meet Windows 11 system requirements — The PC must support Secure Boot"*. You must use the Secure Boot firmware and enable SMM:

```
-machine q35,accel=kvm,smm=on
-global driver=cfi.pflash01,property=secure,value=on
-drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.secboot.fd
-drive if=pflash,format=raw,file=OVMF_VARS.fd
```

The TPM 2.0 swtpm socket is also non-negotiable — Win11 checks for both.

**4. Do not set `bootindex=0` on the install CD.** Hard-pinning the CD as highest-priority boot device overrides Windows' own NVRAM boot-order changes during install, which creates an infinite reinstall loop: after Phase 1 writes `/EFI/Microsoft/Boot/bootmgfw.efi` and a Windows Boot Manager NVRAM entry, the next reboot should prefer that entry, but a forced CD `bootindex=0` keeps sending BDS back to the CD which then reinstalls Windows from scratch. Leave `bootindex` unset on everything and let OVMF use its default boot order (disk first, fall through to CDs on empty disk). Once Setup writes its own Windows Boot Manager entry it takes over automatically.

**5. Windows 11 25H2 hides the power-button action in `powercfg`.** The `SUB_BUTTONS\PBUTTONACTION` setting has `Attributes=1` (hidden) by default on 25H2, so `powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS PBUTTONACTION 3` silently no-ops when using the friendly alias. Fix in autounattend: `powercfg /attributes ... -ATTRIB_HIDE` first, then `setacvalueindex` by full GUID. Without this, the Cocoon-side ACPI power-button shutdown never takes effect even though everything else looks configured.

**6. Setup's Phase 1 → Phase 2 reboot sometimes hangs on QEMU/OVMF.** Windows Setup's `wpeutil reboot` calls EFI `RT::ResetSystem` which doesn't always return under our QEMU + secboot OVMF + virtio-blk configuration — Setup ends up spinning in WinPE at 100 % CPU with zero further disk writes for an indefinite time. The workflow guards against this: if the qcow2 has been >5 GiB and hasn't grown for 20 minutes, it issues a QMP `system_reset` to force a host-level reboot. Cloud Hypervisor production boots (with `rust-hypervisor-firmware`, not OVMF) are unaffected; this only bites the QEMU install pipeline.

#### Build steps

```bash
# 1. Repack the Windows ISO with autounattend at the root + noprompt EFI boot
sudo mount -o loop,ro windows-orig.iso /mnt
cp -a /mnt/. iso_src/
sudo umount /mnt
chmod -R u+w iso_src
cp autounattend.xml iso_src/autounattend.xml
xorriso -as mkisofs -iso-level 3 -J -joliet-long -R \
  -V "WIN11_25H2_UA" \
  -b boot/etfsboot.com -no-emul-boot -boot-load-size 8 -boot-info-table \
  -eltorito-alt-boot \
  -e efi/microsoft/boot/efisys_noprompt.bin -no-emul-boot \
  -o windows.iso iso_src/
rm -rf iso_src

# 2. Disk image
qemu-img create -f qcow2 windows-11-25h2.qcow2 40G

# 3. Writable OVMF vars
cp /usr/share/OVMF/OVMF_VARS_4M.fd OVMF_VARS.fd

# 4. TPM emulator
mkdir -p /tmp/mytpm
swtpm socket --tpmstate dir=/tmp/mytpm \
  --ctrl type=unixio,path=/tmp/swtpm-sock \
  --tpm2 --log level=5 &

# 5. Launch QEMU
qemu-system-x86_64 \
  -machine q35,accel=kvm,smm=on \
  -cpu host,hv_relaxed,hv_spinlocks=0x1fff,hv_vapic,hv_time \
  -m 8G -smp 4 \
  -global driver=cfi.pflash01,property=secure,value=on \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.secboot.fd \
  -drive if=pflash,format=raw,file=OVMF_VARS.fd \
  -drive id=cd0,if=none,file=windows.iso,media=cdrom,readonly=on \
  -device ide-cd,drive=cd0,bus=ide.0 \
  -drive id=cd1,if=none,file=virtio-win-0.1.285.iso,media=cdrom,readonly=on \
  -device ide-cd,drive=cd1,bus=ide.1 \
  -drive if=none,id=root,file=windows-11-25h2.qcow2,format=qcow2 \
  -device virtio-blk-pci,drive=root,disable-legacy=on \
  -device virtio-net-pci,netdev=mynet0,disable-legacy=on \
  -netdev user,id=mynet0,hostfwd=tcp::2222-:22 \
  -chardev socket,id=chrtpm,path=/tmp/swtpm-sock \
  -tpmdev emulator,id=tpm0,chardev=chrtpm \
  -device tpm-tis,tpmdev=tpm0 \
  -device qemu-xhci,id=xhci \
  -device usb-tablet,bus=xhci.0 \
  -display none \
  -serial file:serial.log \
  -monitor tcp:127.0.0.1:4444,server,nowait \
  -qmp tcp:127.0.0.1:4445,server,nowait \
  -daemonize -pidfile qemu.pid
```

Snapshot the screen anytime with `screendump`:

```bash
echo 'screendump /tmp/screen.ppm' | nc -w 1 -q 1 127.0.0.1 4444
convert /tmp/screen.ppm /tmp/screen.png   # imagemagick
```

Setup runs completely unattended from here on: no key spray, no picker click, no CD eject, no manual intervention. The installer takes ~30 minutes to reach OOBE and another ~20-30 minutes for OOBE + FirstLogonCommands. Expect disk growth from 196 K → 7-8 GiB → 15-17 GiB.

#### Wait for install.success, verify, shut down

```bash
# Wait for the marker, with stall-reset fallback
LAST=0; STALL=0
while :; do
  sleep 60
  DISK=$(du -k windows-11-25h2.qcow2 | cut -f1)
  if sshpass -p 'C@c#on160' ssh -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null -p 2222 cocoon@localhost \
      'if exist C:\install.success echo READY' 2>/dev/null | grep -q READY; then
    break
  fi
  if [ "$DISK" -gt 5242880 ] && [ "$DISK" -eq "$LAST" ]; then
    STALL=$((STALL + 60))
    if [ "$STALL" -ge 1200 ]; then
      echo "stall >20 min, forcing QMP system_reset"
      python3 -c "
import socket,time
s=socket.socket(); s.connect(('127.0.0.1',4445)); s.recv(4096)
s.sendall(b'{\"execute\":\"qmp_capabilities\"}\n'); time.sleep(0.3); s.recv(4096)
s.sendall(b'{\"execute\":\"system_reset\"}\n'); time.sleep(0.3)"
      STALL=0
    fi
  else
    STALL=0
  fi
  LAST=$DISK
  echo "$(date) disk=$(du -sh windows-11-25h2.qcow2 | cut -f1) stall=${STALL}s"
done

# Upload and run verify / remediate
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
sshpass -p 'C@c#on160' ssh $SSH_OPTS -p 2222 cocoon@localhost 'if not exist C:\scripts mkdir C:\scripts'
sshpass -p 'C@c#on160' scp $SSH_OPTS -P 2222 scripts/verify.ps1 scripts/remediate.ps1 \
    cocoon@localhost:'C:/scripts/'

# Reboot once so pending updates apply during the reboot (user-reported quirk:
# autounattend's WinRM settings do not persist through the very first post-install
# reboot and must be re-applied by remediate.ps1)
sshpass -p 'C@c#on160' ssh $SSH_OPTS -p 2222 cocoon@localhost 'shutdown /r /t 5 /f'
# wait for SSH to come back, then verify + remediate + re-verify

sshpass -p 'C@c#on160' ssh $SSH_OPTS -p 2222 cocoon@localhost \
    'powershell -ExecutionPolicy Bypass -File C:\scripts\verify.ps1'

# Shut down and compress
sshpass -p 'C@c#on160' ssh $SSH_OPTS -p 2222 cocoon@localhost 'shutdown /s /t 10'
# wait for QEMU to exit
qemu-img convert -O qcow2 -c windows-11-25h2.qcow2 windows-11-25h2.qcow2.tmp
mv windows-11-25h2.qcow2.tmp windows-11-25h2.qcow2
```

Typical sizes: ~17 GiB uncompressed → ~14 GiB after `qemu-img convert -c`.

## autounattend.xml explained

The included [`autounattend.xml`](autounattend.xml) drives the install across three passes.

### windowsPE pass

- **Locale / keyboard**: `SetupUILanguage=en-GB`, `InputLocale=0409:00000409` (US keyboard), `UILanguage=en-GB`. The three fields together tell SetupHost "I already know what language to use, don't ask" — dropping any of them re-enables the 24H2+ language picker even when the XML is at the ISO root.
- **VirtIO driver injection**: auto-loads drivers from D: and E: (dual drive letter handles varying CD-ROM assignment). `viostor` (disk), `NetKVM` (network), `Balloon` (memory). Both `Win11/amd64/{driver}` (attestation layout) and `{driver}/w11/amd64` (standard) paths are searched.
- **Disk partitioning**: wipes Disk 0, creates EFI (100 MB) + MSR (16 MB) + Windows (remaining, NTFS, C:).
- **Image**: `ImageIndex=6` (Windows 11 Pro).
- **Product key**: `VK7JG-NPHTM-C97JM-9MPGT-3V66T` (generic install key, not activation).

### specialize pass

- **BypassNRO**: registry write to skip Win11 mandatory network + Microsoft account during OOBE.
- **ComputerName**: `COCOON-VM` (also re-applied in FirstLogonCommands via `Rename-Computer` because 25H2 sometimes drops this).
- **TimeZone**: Pacific Standard Time.
- **Keyboard**: US (`InputLocale=0409:00000409`).

### oobeSystem pass

- **International-Core**: `InputLocale=0409:00000409` only. The component must be present here for Windows 11 25H2 OOBE to skip the country / keyboard selection screens.
- **OOBE**: hides EULA, online account, wireless setup.
- **User account**: local admin `cocoon` with auto-logon (password base64-encoded in XML).
- **FirstLogonCommands**: 27 commands.

| Order  | Action                       | Notes |
|--------|------------------------------|-------|
| 1-2    | **RDP**                      | `fDenyTSConnections=0` + `Enable-NetFirewallRule` |
| 3-4    | **SSH**                      | `Add-WindowsCapability OpenSSH.Server`, auto-start, firewall rule |
| 5      | **ICMP**                     | Allow ping |
| 6      | **Firewall**                 | Disable all profiles (dev/test environment) |
| 7      | **Hibernate**                | `powercfg /h off` |
| 8-10   | **EMS boot flags**           | `bcdedit /emssettings emsport:1 emsbaudrate:115200`, `/ems on`, `/bootems on` |
| 11     | **TermService**              | Set to auto-start |
| 12     | **EMS-SAC FoD**              | Install `Windows.Desktop.EMS-SAC.Tools~~~~0.0.1.0` — required for a real SAC console on Win11 client |
| 13     | **Network profile**          | Set to Private (required before WinRM AllowUnencrypted) |
| 14-17  | **WinRM**                    | Enable PS Remoting, AllowUnencrypted, Basic auth, firewall on 5985 |
| 18     | **Hostname**                 | Force `Rename-Computer` to `COCOON-VM` (specialize ComputerName unreliable on 25H2) |
| 19     | **virtio-win guest tools**   | Silent install `virtio-win-guest-tools.exe /S` from CD-ROM — drivers + QEMU Guest Agent + spice agent in one shot |
| 20     | **Unhide PBUTTONACTION**     | `powercfg /attributes ... -ATTRIB_HIDE` — see quirk #5 |
| 21-23  | **ACPI power button = Shut down** | `PBUTTONACTION=3` for AC + DC power schemes, referenced by full GUID |
| 24-25  | **Shutdown optimization**    | `WaitToKillServiceTimeout=5000`, `DisableShutdownNamedPipeCheck=1` |
| 26     | **Shutdown without logon**   | Allow remote `shutdown /s /t 0` with no user logged in |
| 27     | **Install marker**           | `cmd /c "echo %date% %time% > C:\install.success"` |

> **Note on WinRM persistence**: `Enable-PSRemoting` + the `AllowUnencrypted`/`Basic` WSMan settings set by orders 14-16 do not always survive the very first post-install reboot on Win11 25H2. `remediate.ps1` re-applies them from the same deterministic settings, and the CI loop reboots → verifies → remediates → re-verifies to make the final image idempotent.

## Post-clone networking

- **DHCP**: no action needed, Windows DHCP client auto-configures on the new NIC.
- **Static IP**: configure via SSH:
  ```
  netsh interface ip set address "Ethernet" static <IP> <MASK> <GW>
  ```

## On-Cloud-Hypervisor serial console

For Windows 11 25H2 client SKUs, a true SAC console requires both parts:

- The EMS boot flags in BCD (`/emssettings`, `/ems on`, `/bootems on`)
- The `Windows.Desktop.EMS-SAC.Tools~~~~0.0.1.0` FoD installed in the guest

Checking only `bcdedit /enum` is a false positive. The supported validation path in this repo is:

- `scripts/firstboot-state.ps1` to wait for the concrete runtime pieces that the FoD drops: `sacdrv.sys`, `sacsess.exe`, `sacdrv` service registration, and no active servicing process
- `scripts/verify.ps1` for in-guest prerequisites: EMS boot flags, `sacdrv.sys`, `sacsess.exe`, `sacdrv` registration, and advisory `ACPI\\PNP0501` visibility
- `scripts/sac_probe.py` against the Cloud Hypervisor serial socket, to prove that `COM1` actually responds as SAC after boot

If the serial socket only shows firmware boot logs and never returns SAC tokens after `CR/LF` and `?`, the image does **not** meet Cocoon's Windows console requirement.

## Licensing

Microsoft licensing prohibits public distribution of Windows disk images. The GHCR package visibility should be restricted to authorized consumers; this repo only ships the automation code (`autounattend.xml`, scripts, workflow).
