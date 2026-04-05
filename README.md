# Windows VM Image

Build automation for Windows 11 25H2 disk images targeting Cloud Hypervisor.

Contents:

- `autounattend.xml` — unattended Windows setup configuration
- `scripts/verify.ps1` + `scripts/remediate.ps1` — post-install verification / remediation loop
- `.github/workflows/build.yml` — headless QEMU/KVM build on `ubuntu-latest`, publishes to GHCR via ORAS

## Pulling a pre-built image

Built images are published as OCI artifacts to GHCR:

```
ghcr.io/cmgs/windows:win11-25h2              # moving alias, latest good build
ghcr.io/cmgs/windows:win11-25h2-<YYYYMMDD>   # dated immutable tag
```

### 1. Pull

```bash
# Requires oras CLI -- https://oras.land
oras pull ghcr.io/cmgs/windows:win11-25h2
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

### 3. Boot it

```bash
qemu-img info windows-11-25h2.qcow2   # sanity check

# On Cloud Hypervisor with our patched firmware:
cloud-hypervisor \
  --kernel /usr/local/share/cloud-hypervisor/CLOUDHV.fd \
  --disk path=windows-11-25h2.qcow2 \
  --cpus boot=2 --memory size=4G \
  --net tap=,mac=,ip=,mask= \
  --serial tty --console off
```

Login is the local admin `cocoon` account set up by `autounattend.xml`. SSH and WinRM are enabled out of the box.

## Building yourself

Two flows share the same automation: **GitHub Actions** (`ubuntu-latest`, free tier, ~2 h, auto-publishes to GHCR) and **local** (any Linux + KVM host).

### Version requirements

| Component        | Version      | Notes                                                                        |
|------------------|--------------|------------------------------------------------------------------------------|
| Cloud Hypervisor | **v51+**     | Use [cocoonstack/cloud-hypervisor `dev`][ch-fork] for full Windows support   |
| Firmware         | **patched**  | Use [cocoonstack/rust-hypervisor-firmware `dev`][fw-fork] for ACPI shutdown  |
| virtio-win       | **0.1.285**  | Latest stable; 0.1.240 also works on upstream CH without patches             |
| QEMU (build)     | **≥ 8.x**    | Build host only — production runs on Cloud Hypervisor                        |
| OVMF (build)     | **secboot**  | `OVMF_CODE_4M.secboot.fd` — Win11 requires Secure Boot, see quirk #3         |

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
gh workflow run build.yml --repo CMGS/windows -f version_tag=win11-25h2
```

Requires one repository secret:

- `WINDOWS_ISO_URL` — signed download URL for the Windows 11 25H2 ISO. Microsoft licensing prohibits bundling the ISO in the repo or any artifact, so fetch it at build time.

The workflow:

1. Frees ~30 GiB of preinstalled SDKs from the runner (default ubuntu-latest has ~14 GiB free, not enough for `windows.iso` + `virtio-win.iso` + growing qcow2)
2. Boots QEMU with Secure Boot OVMF + swtpm TPM 2.0
3. Injects Enter keys via the QEMU monitor to defeat the "Press any key to boot from CD" prompt
4. Runs unattended install from `autounattend.xml` (delivered as a third CD-ROM; see quirk #2)
5. Polls SSH for `C:\install.success` marker
6. Runs `verify.ps1`, reboots, re-verifies, and applies `remediate.ps1` on failure (up to 3 attempts)
7. Shuts the VM down cleanly, compresses the qcow2, splits it, and pushes to GHCR via ORAS

### Building locally

#### Prerequisites

```bash
sudo apt-get install -y \
  qemu-system-x86 qemu-utils \
  ovmf swtpm mtools genisoimage \
  openssh-client sshpass netcat-openbsd
```

Plus a Windows 11 25H2 ISO and [virtio-win-0.1.285.iso](https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.285-1/).

#### Quirks worth knowing upfront

Understanding these four points avoids hours of debugging. All four are encoded into `build.yml`.

**1. q35 `-cdrom` shorthand puts the Windows ISO where OVMF cannot boot from it.** Both `-cdrom windows.iso` and a second `-drive ...,media=cdrom` land on q35's AHCI controller in positions where OVMF's BdsDxe reports `Not Found` for Boot0001. You must attach each CD-ROM explicitly on a dedicated SATA port, and each `ide.N` bus only supports 1 unit:

```
-drive id=cd0,if=none,file=windows.iso,media=cdrom,readonly=on
-device ide-cd,drive=cd0,bus=ide.0,bootindex=0
-drive id=cd1,if=none,file=virtio-win.iso,media=cdrom,readonly=on
-device ide-cd,drive=cd1,bus=ide.1
```

**2. q35 has no working floppy for Windows PE.** The classic "deliver autounattend.xml on a FAT floppy" trick fails silently: the `-drive if=floppy` device is visible at the QEMU level but Windows PE's driver stack does not enumerate it, so the unattend file is never read, Setup falls to its GUI, and the disk stays at 196 K forever while the (headless) screen waits for a click. Fix: pack the XML into a tiny ISO and attach it as a third CD-ROM. Windows Setup searches every CD-ROM for `autounattend.xml` at the root:

```bash
genisoimage -o autounattend.iso -J -r autounattend.xml
```

```
-drive id=cd2,if=none,file=autounattend.iso,media=cdrom,readonly=on
-device ide-cd,drive=cd2,bus=ide.2
```

**3. Windows 11 25H2 refuses to install without Secure Boot.** If you use `OVMF_CODE_4M.fd` (non-secboot) to dodge CD-ROM boot issues, the installer reads autounattend.xml, starts Setup, and then immediately aborts with *"This PC doesn't currently meet Windows 11 system requirements — The PC must support Secure Boot"*. You **must** use the Secure Boot firmware and enable SMM:

```
-machine q35,accel=kvm,smm=on
-global driver=cfi.pflash01,property=secure,value=on
-drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.secboot.fd
-drive if=pflash,format=raw,file=OVMF_VARS.fd
```

The TPM 2.0 swtpm socket is also non-negotiable — Win11 checks for both.

**4. Windows Boot Manager shows "Press any key to boot from CD" even on UEFI / first install.** The prompt is not a firmware prompt — it's inside `bootmgfw.efi` (Windows Boot Manager) that OVMF loads from the ISO. It appears on **every** CD boot, first install and reboots alike. Microsoft's design is that after install you normally *don't* press a key, so bootmgr times out in ~5 seconds, OVMF marks Boot0001 `failed to start: Time out`, and you fall through to the installed disk. The prompt still renders on first boot, and there's no way to auto-accept it from the ISO side.

In a headless build we have no keyboard, so the serial log shows:

```
BdsDxe: loading Boot0001 "UEFI QEMU DVD-ROM QM00001" from ...
BdsDxe: starting Boot0001 "UEFI QEMU DVD-ROM QM00001" from ...
BdsDxe: failed to start Boot0001 ...: Time out
```

`Time out` is Windows bootmgr exiting after nobody pressed a key — not OVMF giving up on the device. Fix: attach a QEMU monitor, then spray Enter keys into it during the window between OVMF loading bootmgfw.efi and the bootmgr timeout:

```bash
qemu-system-x86_64 ... \
  -monitor tcp:127.0.0.1:4444,server,nowait \
  -daemonize -pidfile qemu.pid

for delay in 2 1 1 1 1 1 1 1 1 1 1 1 1 1 1; do
  sleep $delay
  echo 'sendkey ret' | nc -w 1 -q 1 127.0.0.1 4444
done
```

Fifteen presses from +2 s through +17 s cover cold QEMU start + OVMF boot time.

**5. Windows 11 24H2+ Setup (SetupHost.exe) shows two mandatory picker screens before it reads `autounattend.xml`.** Starting with 24H2, Microsoft replaced classic `setup.exe` with a new `SetupHost.exe`-based modernized installer. The very first two screens — **"Select language settings"** followed by **"Select keyboard settings"** — are drawn by the modern UI *before* `SetupHost` ever opens the unattend file, so there is nothing you can put inside `Microsoft-Windows-International-Core-WinPE` (not `InputLocale`, not `SystemLocale`, not `UILanguage`, not `SetupUILanguage`) that will skip them. They must be clicked.

Both screens pre-populate with the ISO's native locale ("English (United Kingdom)" for the EN-International ISO), so accepting the defaults is fine. The Next button exposes an underlined `N` accelerator, so **`Alt+N`** activates it regardless of where keyboard focus currently is. Spray Alt+N every few seconds and bail out as soon as the disk starts growing (that's Setup reading autounattend and starting the partitioner):

```bash
for i in $(seq 1 60); do
  sleep 3
  echo 'sendkey alt-n' | nc -w 1 -q 1 127.0.0.1 4444
  DISK_K=$(du -k windows-11-25h2.qcow2 | cut -f1)
  if [ "$DISK_K" -gt 500000 ]; then
    echo "Setup past pickers, disk=${DISK_K}K"
    break
  fi
done
```

Do **not** send bare `Enter` keys during this phase: if `Enter` ever lands while keyboard focus is on the on-screen "Support" link (which happens when the key falls through from the bootmgr spray into the Setup UI) it opens a modal "Unable to open link" dialog that then swallows every subsequent Enter. `Alt+N` always targets the Next button, not the focused link.

**6. Eject the install CDs from the QEMU monitor before the first post-install reboot.** Because we pin the Windows ISO to `bootindex=0` so OVMF always tries it first (required to defeat quirk #4 on the initial install), a warm reboot of the installed VM falls into an infinite BDS loop: bootmgr on the CD renders "Press any key" for 5 s, bootmgr exits via timeout, OVMF marks Boot0001 failed, then OVMF re-enters BDS and tries Boot0001 *again* instead of Boot0002 (Windows Boot Manager on the disk). Two CPUs sit pegged at 100 % executing OVMF BDS forever and SSH never comes back. Ejecting the CDs through the monitor between the "install.success" marker and `shutdown /r` removes Boot0001 from the candidate list; OVMF then picks Boot0002 on the very first BDS pass and Windows boots cleanly:

```bash
printf 'eject -f cd0\n' | nc -w 1 -q 1 127.0.0.1 4444
printf 'eject -f cd1\n' | nc -w 1 -q 1 127.0.0.1 4444
printf 'eject -f cd2\n' | nc -w 1 -q 1 127.0.0.1 4444
```

#### Build steps

```bash
# 1. Disk image
qemu-img create -f qcow2 windows-11-25h2.qcow2 40G

# 2. Writable OVMF vars
cp /usr/share/OVMF/OVMF_VARS_4M.fd OVMF_VARS.fd

# 3. TPM emulator
mkdir -p /tmp/mytpm
swtpm socket --tpmstate dir=/tmp/mytpm \
  --ctrl type=unixio,path=/tmp/swtpm-sock \
  --tpm2 --log level=5 &

# 4. autounattend as ISO (see quirk #2)
genisoimage -o autounattend.iso -J -r autounattend.xml

# 5. Launch QEMU
qemu-system-x86_64 \
  -machine q35,accel=kvm,smm=on \
  -cpu host,hv_relaxed,hv_spinlocks=0x1fff,hv_vapic,hv_time \
  -m 8G -smp 4 \
  -global driver=cfi.pflash01,property=secure,value=on \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.secboot.fd \
  -drive if=pflash,format=raw,file=OVMF_VARS.fd \
  -drive id=cd0,if=none,file=windows.iso,media=cdrom,readonly=on \
  -device ide-cd,drive=cd0,bus=ide.0,bootindex=0 \
  -drive id=cd1,if=none,file=virtio-win-0.1.285.iso,media=cdrom,readonly=on \
  -device ide-cd,drive=cd1,bus=ide.1 \
  -drive id=cd2,if=none,file=autounattend.iso,media=cdrom,readonly=on \
  -device ide-cd,drive=cd2,bus=ide.2 \
  -drive if=none,id=root,file=windows-11-25h2.qcow2,format=qcow2 \
  -device virtio-blk-pci,drive=root,disable-legacy=on \
  -device virtio-net-pci,netdev=mynet0,disable-legacy=on \
  -netdev user,id=mynet0,hostfwd=tcp::2222-:22 \
  -chardev socket,id=chrtpm,path=/tmp/swtpm-sock \
  -tpmdev emulator,id=tpm0,chardev=chrtpm \
  -device tpm-tis,tpmdev=tpm0 \
  -display none \
  -serial file:serial.log \
  -monitor tcp:127.0.0.1:4444,server,nowait \
  -daemonize -pidfile qemu.pid

# 6. Defeat "Press any key" (quirk #4)
for delay in 2 1 1 1 1 1 1 1 1 1 1 1 1 1 1; do
  sleep $delay
  echo 'sendkey ret' | nc -w 1 -q 1 127.0.0.1 4444
done

# 7. Click past Win11 25H2 Setup language + keyboard pickers (quirk #5)
for i in $(seq 1 60); do
  sleep 3
  echo 'sendkey alt-n' | nc -w 1 -q 1 127.0.0.1 4444
  DISK_K=$(du -k windows-11-25h2.qcow2 | cut -f1)
  if [ "$DISK_K" -gt 500000 ]; then break; fi
done
```

Snapshot the screen anytime with `screendump`:

```bash
echo 'screendump /tmp/screen.ppm' | nc -w 1 -q 1 127.0.0.1 4444
convert /tmp/screen.ppm /tmp/screen.png   # imagemagick
```

The installer takes ~30 minutes to reach OOBE and another ~20-30 minutes for OOBE + FirstLogonCommands. Expect disk growth from 196 K → 7-8 GiB → 15-17 GiB.

#### Wait for install.success, verify, shut down

```bash
# Wait for the marker
while true; do
  sleep 60
  sshpass -p 'C@c#on160' ssh -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null -p 2222 cocoon@localhost \
      'if exist C:\install.success echo READY' 2>/dev/null | grep -q READY && break
  echo "$(date) still waiting, disk=$(du -sh windows-11-25h2.qcow2 | cut -f1)"
done

# Upload and run verify / remediate
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
sshpass -p 'C@c#on160' ssh $SSH_OPTS -p 2222 cocoon@localhost "mkdir C:\scripts"
sshpass -p 'C@c#on160' scp $SSH_OPTS -P 2222 scripts/verify.ps1 scripts/remediate.ps1 \
    cocoon@localhost:"C:\scripts\\"
sshpass -p 'C@c#on160' ssh $SSH_OPTS -p 2222 cocoon@localhost \
    "powershell -ExecutionPolicy Bypass -File C:\scripts\verify.ps1"

# Shut down and compress
sshpass -p 'C@c#on160' ssh $SSH_OPTS -p 2222 cocoon@localhost "shutdown /s /t 10"
# wait for QEMU to exit
qemu-img convert -O qcow2 -c windows-11-25h2.qcow2 windows-11-25h2.qcow2.tmp
mv windows-11-25h2.qcow2.tmp windows-11-25h2.qcow2
```

Typical sizes: ~17 GiB uncompressed → ~14 GiB after `qemu-img convert -c`.

## autounattend.xml explained

The included [`autounattend.xml`](autounattend.xml) drives the install across three passes.

### windowsPE pass

- **Keyboard**: US (`InputLocale=0409:00000409`). Nothing else in `Microsoft-Windows-International-Core-WinPE` is set — all other locale fields inherit from the image default, so the same autounattend works for English International, English (US), or any other edition.
- **VirtIO driver injection**: auto-loads drivers from D: and E: (dual drive letter handles varying CD-ROM assignment). `viostor` (disk), `NetKVM` (network), `Balloon` (memory). Both `Win11/amd64/{driver}` (attestation layout) and `{driver}/w11/amd64` (standard) paths are searched.
- **Disk partitioning**: wipes Disk 0, creates EFI (100 MB) + MSR (16 MB) + Windows (remaining, NTFS, C:).
- **Image**: `ImageIndex=6` (Windows 11 Pro).
- **Product key**: `VK7JG-NPHTM-C97JM-9MPGT-3V66T` (generic install key, not activation).

### specialize pass

- **BypassNRO**: registry write to skip Win11 mandatory network + Microsoft account during OOBE.
- **ComputerName**: `COCOON-VM` (also re-applied in FirstLogonCommands via `Rename-Computer` because 25H2 sometimes drops this).
- **TimeZone**: Pacific Standard Time.
- **Keyboard**: US (same `InputLocale` only).

### oobeSystem pass

- **International-Core**: `InputLocale=0409:00000409` only. The component must be present here for Windows 11 25H2 OOBE to skip the country / keyboard selection screens, but we deliberately do not pin `SystemLocale`/`UILanguage`/`UserLocale` so the image default wins.
- **OOBE**: hides EULA, online account, wireless setup.
- **User account**: local admin `cocoon` with auto-logon (password base64-encoded in XML).
- **FirstLogonCommands**: 26 commands.

| Order  | Action                       | Notes |
|--------|------------------------------|-------|
| 1-2    | **RDP**                      | `fDenyTSConnections=0` + `Enable-NetFirewallRule` |
| 3-4    | **SSH**                      | `Add-WindowsCapability OpenSSH.Server`, auto-start, firewall rule |
| 5      | **ICMP**                     | Allow ping |
| 6      | **Firewall**                 | Disable all profiles (dev/test environment) |
| 7      | **Hibernate**                | `powercfg /h off` |
| 8-10   | **SAC / EMS**                | `bcdedit /emssettings emsport:1 emsbaudrate:115200`, `/ems on`, `/bootems on` — enables the in-kernel SAC serial console (no FoD needed; the `Windows.Desktop.EMS-SAC.Tools` capability only adds optional extra admin CLI tools and is NotPresent on EN-Intl Pro SKU, so we don't bother installing it) |
| 11     | **TermService**              | Set to auto-start |
| 12     | **Network profile**          | Set to Private (required before WinRM AllowUnencrypted) |
| 13-16  | **WinRM**                    | Enable PS Remoting, AllowUnencrypted, Basic auth, firewall on 5985 |
| 17     | **Hostname**                 | Force `Rename-Computer` to `COCOON-VM` (specialize ComputerName unreliable on 25H2) |
| 18     | **virtio-win guest tools**   | Silent install `virtio-win-guest-tools.exe /S` from CD-ROM — drivers + QEMU Guest Agent + spice agent in one shot |
| 19     | **Unhide PBUTTONACTION**     | `powercfg /attributes ... -ATTRIB_HIDE` — on Win11 25H2 the physical power-button setting is hidden (Attributes=1), so every subsequent `powercfg /setacvalueindex SUB_BUTTONS PBUTTONACTION ...` silently no-ops until the setting is unhidden |
| 20-22  | **ACPI power button = Shut down** | `PBUTTONACTION=3` for AC + DC power schemes, referenced by full GUID because the friendly alias does not resolve while the setting is hidden |
| 23-24  | **Shutdown optimization**    | `WaitToKillServiceTimeout=5000`, `DisableShutdownNamedPipeCheck=1` |
| 25     | **Shutdown without logon**   | Allow remote `shutdown /s /t 0` with no user logged in |
| 26     | **Install marker**           | `cmd /c "echo %date% %time% > C:\install.success"` |

## Post-clone networking

- **DHCP**: no action needed, Windows DHCP client auto-configures on the new NIC.
- **Static IP**: configure via SAC serial console:
  ```
  cmd
  ch -si 1
  netsh interface ip set address "Ethernet" static <IP> <MASK> <GW>
  ```
  See the [Cloud Hypervisor Windows documentation](https://github.com/cloud-hypervisor/cloud-hypervisor/blob/main/docs/windows.md) for details.

## Licensing

Microsoft licensing prohibits public distribution of Windows disk images. The GHCR package visibility should be restricted to authorized consumers; this repo only ships the automation code (`autounattend.xml`, scripts, workflow).
