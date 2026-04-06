#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORKDIR=${WORKDIR:-"$ROOT_DIR/work/qemu-build"}
ARTIFACT_DIR=${ARTIFACT_DIR:-"$WORKDIR/artifacts"}
WINDOWS_ISO_URL=${WINDOWS_ISO_URL:?set WINDOWS_ISO_URL}
VIRTIO_WIN_URL=${VIRTIO_WIN_URL:-"https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.285-1/virtio-win-0.1.285.iso"}
WIN_PASS=${WIN_PASS:-"C@c#on160"}
QCOW2_NAME=${QCOW2_NAME:-"windows-11-25h2.qcow2"}
DISK_SIZE=${DISK_SIZE:-40G}
SSH_PORT=${SSH_PORT:-2222}
MONITOR_PORT=${MONITOR_PORT:-4444}
QMP_PORT=${QMP_PORT:-4445}
SSH_COMMAND_TIMEOUT=${SSH_COMMAND_TIMEOUT:-300}
REBOOT_SSH_WAIT_TRIES=${REBOOT_SSH_WAIT_TRIES:-120}
FIRSTBOOT_SETTLE_TIMEOUT=${FIRSTBOOT_SETTLE_TIMEOUT:-1800}
FIRSTBOOT_SETTLE_INTERVAL=${FIRSTBOOT_SETTLE_INTERVAL:-15}
SCREENSHOT_PNG=${SCREENSHOT_PNG:-"$ARTIFACT_DIR/qemu-progress.png"}
SCREENSHOT_PPM="$ARTIFACT_DIR/qemu-progress.ppm"

QEMU_PID=""
SWTPM_PID=""
SCREENSHOT_PID=""

mkdir -p "$WORKDIR" "$ARTIFACT_DIR"

ssh_opts=(
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o ConnectTimeout=10
  -o LogLevel=ERROR
)

cleanup() {
  set +e
  if [[ -n "${SCREENSHOT_PID}" ]]; then
    kill "${SCREENSHOT_PID}" 2>/dev/null || true
  fi
  if [[ -n "${QEMU_PID}" ]]; then
    kill "${QEMU_PID}" 2>/dev/null || true
    wait "${QEMU_PID}" 2>/dev/null || true
  fi
  if [[ -n "${SWTPM_PID}" ]]; then
    kill "${SWTPM_PID}" 2>/dev/null || true
    wait "${SWTPM_PID}" 2>/dev/null || true
  fi
  rm -f "$SCREENSHOT_PPM"
}
trap cleanup EXIT

log() {
  printf '[build-qemu] %s\n' "$*"
}

ssh_run() {
  sshpass -p "$WIN_PASS" ssh "${ssh_opts[@]}" -p "$SSH_PORT" cocoon@localhost "$@"
}

ssh_run_timeout() {
  local timeout_s=$1
  shift
  timeout --foreground "$timeout_s" \
    sshpass -p "$WIN_PASS" ssh "${ssh_opts[@]}" -p "$SSH_PORT" cocoon@localhost "$@"
}

scp_to() {
  sshpass -p "$WIN_PASS" scp "${ssh_opts[@]}" -P "$SSH_PORT" "$@"
}

wait_for_ssh() {
  local tries=${1:-60}
  local label=${2:-guest SSH}
  for _ in $(seq 1 "$tries"); do
    if ssh_run_timeout 15 "echo ok" 2>/dev/null | grep -q ok; then
      return 0
    fi
    sleep 5
  done
  log "$label did not come back after $tries attempts"
  return 1
}

run_guest_ps_file() {
  local timeout_s=$1
  local script_path=$2
  shift 2
  ssh_run_timeout "$timeout_s" \
    "powershell -NoProfile -ExecutionPolicy Bypass -File $script_path $*"
}

wait_for_firstboot_settle() {
  local phase=$1
  local timeout_s=$2
  local log_file="$ARTIFACT_DIR/${phase}-firstboot-state.log"
  local waited=0

  : >"$log_file"

  while (( waited <= timeout_s )); do
    local output=""
    local clean_output=""
    local rc=0
    set +e
    output=$(run_guest_ps_file 90 'C:\scripts\firstboot-state.ps1' 2>&1)
    rc=$?
    set -e
    clean_output=$(printf '%s\n' "$output" | tr -d '\r')

    {
      printf -- '--- %s waited=%ss rc=%s ---%s' "$(date -u +%FT%TZ)" "$waited" "$rc" $'\n'
      printf '%s\n' "$clean_output"
    } >>"$log_file"

    if [[ "$rc" -eq 0 ]]; then
      local sacdrv_present=""
      local sacsess_present=""
      local sacdrv_registered=""
      local servicing_count=""

      sacdrv_present=$(printf '%s\n' "$clean_output" | awk -F= '/^SACDRV_PRESENT=/{print $2}')
      sacsess_present=$(printf '%s\n' "$clean_output" | awk -F= '/^SACSESS_PRESENT=/{print $2}')
      sacdrv_registered=$(printf '%s\n' "$clean_output" | awk -F= '/^SACDRV_REGISTERED=/{print $2}')
      servicing_count=$(printf '%s\n' "$clean_output" | awk -F= '/^SERVICING_PROCESS_COUNT=/{print $2}')

      log "$phase settle: sacdrv=${sacdrv_present:-?} sacsess=${sacsess_present:-?} registered=${sacdrv_registered:-?} servicing=${servicing_count:-?}"
      if [[ "$sacdrv_present" == "True" && "$sacsess_present" == "True" && "$sacdrv_registered" == "True" && "$servicing_count" == "0" ]]; then
        return 0
      fi
    else
      log "$phase settle probe failed (rc=$rc), retrying"
    fi

    sleep "$FIRSTBOOT_SETTLE_INTERVAL"
    waited=$((waited + FIRSTBOOT_SETTLE_INTERVAL))
  done

  return 1
}

qmp_reset() {
  python3 - <<PY
import socket
import time

s = socket.create_connection(("127.0.0.1", ${QMP_PORT}))
s.recv(4096)
s.sendall(b'{"execute":"qmp_capabilities"}\n')
time.sleep(0.3)
s.recv(4096)
s.sendall(b'{"execute":"system_reset"}\n')
time.sleep(0.3)
print(s.recv(4096).decode(errors="replace"))
s.close()
PY
}

update_screenshot() {
  while kill -0 "$QEMU_PID" 2>/dev/null; do
    echo "screendump $SCREENSHOT_PPM" | nc -w 1 -q 1 127.0.0.1 "$MONITOR_PORT" >/dev/null 2>&1 || true
    sleep 1
    convert "$SCREENSHOT_PPM" "$SCREENSHOT_PNG" 2>/dev/null || true
    rm -f "$SCREENSHOT_PPM"
    sleep 60
  done
}

log "preparing workdir at $WORKDIR"
rm -rf "$WORKDIR/iso_src" "$WORKDIR/mytpm"
rm -f \
  "$WORKDIR/$QCOW2_NAME" \
  "$WORKDIR/OVMF_VARS.fd" \
  "$WORKDIR/windows.iso" \
  "$WORKDIR/qemu.pid" \
  "$WORKDIR/qemu.log" \
  "$WORKDIR/serial.log" \
  "$WORKDIR/install.success.check.log" \
  "$WORKDIR/pre-reboot-verify.log" \
  "$WORKDIR/post-reboot-verify.log" \
  "$WORKDIR/remediate.log"

if [[ ! -f "$WORKDIR/windows-orig.iso" ]]; then
  log "downloading Windows ISO"
  curl -fL --retry 3 --retry-delay 5 -o "$WORKDIR/windows-orig.iso" "$WINDOWS_ISO_URL"
fi

if [[ ! -f "$WORKDIR/virtio-win.iso" ]]; then
  log "downloading virtio-win ISO"
  curl -fL --retry 3 --retry-delay 5 -o "$WORKDIR/virtio-win.iso" "$VIRTIO_WIN_URL"
fi

log "repacking Windows ISO with autounattend.xml"
mkdir -p "$WORKDIR/iso_src"
sudo mount -o loop,ro "$WORKDIR/windows-orig.iso" /mnt
cp -a /mnt/. "$WORKDIR/iso_src/"
sudo umount /mnt
chmod -R u+w "$WORKDIR/iso_src"
cp "$ROOT_DIR/autounattend.xml" "$WORKDIR/iso_src/autounattend.xml"
xorriso -as mkisofs \
  -iso-level 3 \
  -J -joliet-long -R \
  -V "WIN11_25H2_UA" \
  -b boot/etfsboot.com -no-emul-boot -boot-load-size 8 -boot-info-table \
  -eltorito-alt-boot \
  -e efi/microsoft/boot/efisys_noprompt.bin -no-emul-boot \
  -o "$WORKDIR/windows.iso" \
  "$WORKDIR/iso_src/"
rm -rf "$WORKDIR/iso_src"

qemu-img create -f qcow2 "$WORKDIR/$QCOW2_NAME" "$DISK_SIZE" >/dev/null
cp /usr/share/OVMF/OVMF_VARS_4M.fd "$WORKDIR/OVMF_VARS.fd"

mkdir -p "$WORKDIR/mytpm"
setsid swtpm socket \
  --tpmstate dir="$WORKDIR/mytpm" \
  --ctrl type=unixio,path="$WORKDIR/swtpm.sock" \
  --tpm2 --log level=1 \
  </dev/null >"$ARTIFACT_DIR/swtpm.log" 2>&1 &
SWTPM_PID=$!
sleep 2
test -S "$WORKDIR/swtpm.sock"

log "launching QEMU installer"
qemu-system-x86_64 \
  -machine q35,accel=kvm,smm=on \
  -cpu host,hv_relaxed,hv_spinlocks=0x1fff,hv_vapic,hv_time \
  -m 8G -smp 4 \
  -global driver=cfi.pflash01,property=secure,value=on \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.secboot.fd \
  -drive if=pflash,format=raw,file="$WORKDIR/OVMF_VARS.fd" \
  -drive id=cd0,if=none,file="$WORKDIR/windows.iso",media=cdrom,readonly=on \
  -device ide-cd,drive=cd0,bus=ide.0 \
  -drive id=cd1,if=none,file="$WORKDIR/virtio-win.iso",media=cdrom,readonly=on \
  -device ide-cd,drive=cd1,bus=ide.1 \
  -drive if=none,id=root,file="$WORKDIR/$QCOW2_NAME",format=qcow2 \
  -device virtio-blk-pci,drive=root,disable-legacy=on \
  -device virtio-net-pci,netdev=mynet0,disable-legacy=on \
  -netdev user,id=mynet0,hostfwd=tcp::${SSH_PORT}-:22 \
  -chardev socket,id=chrtpm,path="$WORKDIR/swtpm.sock" \
  -tpmdev emulator,id=tpm0,chardev=chrtpm \
  -device tpm-tis,tpmdev=tpm0 \
  -device qemu-xhci,id=xhci \
  -device usb-tablet,bus=xhci.0 \
  -vnc 127.0.0.1:0 \
  -serial file:"$ARTIFACT_DIR/qemu-serial.log" \
  -monitor tcp:127.0.0.1:${MONITOR_PORT},server,nowait \
  -qmp tcp:127.0.0.1:${QMP_PORT},server,nowait \
  -display none \
  -daemonize -pidfile "$WORKDIR/qemu.pid"
QEMU_PID=$(cat "$WORKDIR/qemu.pid")

for _ in 1 2 3 4 5; do
  echo '' | nc -w 1 -q 1 127.0.0.1 "$MONITOR_PORT" >/dev/null 2>&1 && break
  sleep 1
done

update_screenshot >"$ARTIFACT_DIR/screenshot.log" 2>&1 &
SCREENSHOT_PID=$!

log "waiting for install.success"
MAX_WAIT=7200
ELAPSED=0
LAST_DISK=0
STALL_START=0
while (( ELAPSED < MAX_WAIT )); do
  sleep 60
  ELAPSED=$((ELAPSED + 60))
  if ! kill -0 "$QEMU_PID" 2>/dev/null; then
    log "QEMU died during install"
    exit 1
  fi
  DISK_K=$(du -k "$WORKDIR/$QCOW2_NAME" | cut -f1)
  DISK_H=$(du -sh "$WORKDIR/$QCOW2_NAME" | cut -f1)
  if sshpass -p "$WIN_PASS" ssh "${ssh_opts[@]}" -p "$SSH_PORT" cocoon@localhost \
      "if exist C:\\install.success echo READY" 2>/dev/null | tee -a "$WORKDIR/install.success.check.log" | grep -q READY; then
    log "install.success detected at ${ELAPSED}s (disk=${DISK_H})"
    break
  fi

  if [[ "$DISK_K" -gt 5242880 && "$DISK_K" -eq "$LAST_DISK" ]]; then
    if [[ "$STALL_START" -eq 0 ]]; then
      STALL_START=$ELAPSED
    fi
    if (( ELAPSED - STALL_START >= 1200 )); then
      log "disk stalled for 20min, issuing QMP system_reset"
      qmp_reset | tee -a "$ARTIFACT_DIR/qmp-reset.log"
      STALL_START=0
    fi
  else
    STALL_START=0
  fi

  LAST_DISK=$DISK_K
  log "[${ELAPSED}s] disk=${DISK_H}"
done

if (( ELAPSED >= MAX_WAIT )); then
  log "timed out waiting for install.success"
  exit 1
fi

log "copying verification scripts"
ssh_run "if not exist C:\\scripts mkdir C:\\scripts" >/dev/null 2>&1 || true
scp_to \
  "$ROOT_DIR/scripts/verify.ps1" \
  "$ROOT_DIR/scripts/remediate.ps1" \
  "$ROOT_DIR/scripts/firstboot-state.ps1" \
  cocoon@localhost:"C:/scripts/"

log "capturing pre-reboot first-boot state"
set +e
run_guest_ps_file 90 'C:\scripts\firstboot-state.ps1' \
  | tee "$ARTIFACT_DIR/pre-reboot-firstboot-state.log"
PRE_STATE_RC=${PIPESTATUS[0]}
set -e
if [[ "$PRE_STATE_RC" -ne 0 ]]; then
  log "pre-reboot state probe returned rc=$PRE_STATE_RC; continuing to planned reboot"
fi

log "rebooting guest once to flush first-boot state"
ssh_run "shutdown /r /t 5" >/dev/null 2>&1 || true
sleep 30
wait_for_ssh "$REBOOT_SSH_WAIT_TRIES" "post-install reboot SSH"
sleep 15

log "waiting for post-reboot SAC runtime to settle"
if ! wait_for_firstboot_settle "post-reboot" "$FIRSTBOOT_SETTLE_TIMEOUT"; then
  log "post-reboot SAC runtime never settled"
  exit 1
fi

for attempt in 1 2 3; do
  log "post-reboot verification attempt $attempt/3"
  set +e
  run_guest_ps_file "$SSH_COMMAND_TIMEOUT" 'C:\scripts\verify.ps1' \
    | tee "$ARTIFACT_DIR/post-reboot-verify-attempt-${attempt}.log"
  VERIFY_RC=${PIPESTATUS[0]}
  set -e
  if [[ "$VERIFY_RC" -eq 0 ]]; then
    break
  fi
  if [[ "$attempt" -eq 3 ]]; then
    log "verification still failing after remediation"
    exit 1
  fi
  log "running remediation"
  set +e
  run_guest_ps_file "$SSH_COMMAND_TIMEOUT" 'C:\scripts\remediate.ps1' \
    | tee "$ARTIFACT_DIR/remediate-attempt-${attempt}.log"
  REMEDIATE_RC=${PIPESTATUS[0]}
  set -e
  if [[ "$REMEDIATE_RC" -ne 0 ]]; then
    log "remediation failed with rc=$REMEDIATE_RC"
    exit 1
  fi
  ssh_run "shutdown /r /t 5" >/dev/null 2>&1 || true
  sleep 30
  wait_for_ssh "$REBOOT_SSH_WAIT_TRIES" "post-remediation reboot SSH"
  sleep 15
  if ! wait_for_firstboot_settle "post-remediate-${attempt}" "$FIRSTBOOT_SETTLE_TIMEOUT"; then
    log "post-remediation SAC runtime never settled"
    exit 1
  fi
done

log "shutting down QEMU guest cleanly"
ssh_run "shutdown /s /t 10" >/dev/null 2>&1 || true
for _ in $(seq 1 120); do
  if ! kill -0 "$QEMU_PID" 2>/dev/null; then
    QEMU_PID=""
    break
  fi
  sleep 1
done
if [[ -n "${QEMU_PID}" ]]; then
  log "QEMU did not exit after shutdown"
  exit 1
fi

printf '%s\n' "$WORKDIR/$QCOW2_NAME" >"$ARTIFACT_DIR/qcow2.path"
log "build completed: $WORKDIR/$QCOW2_NAME"
