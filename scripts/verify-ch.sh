#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORKDIR=${WORKDIR:-"$ROOT_DIR/work/ch-verify"}
ARTIFACT_DIR=${ARTIFACT_DIR:-"$WORKDIR/artifacts"}
QCOW2_PATH=${QCOW2_PATH:?set QCOW2_PATH}
WIN_PASS=${WIN_PASS:-"C@c#on160"}
CLOUD_HYPERVISOR_BIN=${CLOUD_HYPERVISOR_BIN:-/usr/local/bin/cloud-hypervisor}
FIRMWARE_PATH=${FIRMWARE_PATH:-/usr/local/share/cloud-hypervisor/CLOUDHV.fd}
SSH_COMMAND_TIMEOUT=${SSH_COMMAND_TIMEOUT:-300}
CH_CPU_COUNT=${CH_CPU_COUNT:-4}
CH_MEMORY_SIZE=${CH_MEMORY_SIZE:-8G}
BRIDGE_NAME=${BRIDGE_NAME:-br-ch}
TAP_NAME=${TAP_NAME:-tap-ch}
SUBNET_CIDR=${SUBNET_CIDR:-192.168.100.1/24}
DHCP_RANGE_START=${DHCP_RANGE_START:-192.168.100.100}
DHCP_RANGE_END=${DHCP_RANGE_END:-192.168.100.200}
ROUTER_IP=${ROUTER_IP:-192.168.100.1}
GUEST_MAC=${GUEST_MAC:-52:54:00:dc:7f:ba}
SERIAL_SOCKET=${SERIAL_SOCKET:-"$WORKDIR/ch-serial.sock"}
API_SOCKET=${API_SOCKET:-"$WORKDIR/ch-api.sock"}
LEASE_FILE="$WORKDIR/dnsmasq.leases"
DNSMASQ_CONF="$WORKDIR/dnsmasq.conf"
DNSMASQ_LOG="$ARTIFACT_DIR/dnsmasq.log"
DNSMASQ_STDERR="$ARTIFACT_DIR/dnsmasq-stderr.log"
CH_LOG="$ARTIFACT_DIR/cloud-hypervisor.log"
CH_PID=""
DNSMASQ_PID=""
SOCAT_PID=""
GUEST_IP=""

mkdir -p "$WORKDIR" "$ARTIFACT_DIR"
rm -f "$SERIAL_SOCKET" "$API_SOCKET" "$LEASE_FILE" "$DNSMASQ_CONF" "$DNSMASQ_LOG" "$DNSMASQ_STDERR"

ssh_opts=(
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o ConnectTimeout=10
  -o LogLevel=ERROR
)

log() {
  printf '[verify-ch] %s\n' "$*"
}

cleanup() {
  set +e
  if [[ -n "${SOCAT_PID}" ]]; then
    kill "${SOCAT_PID}" 2>/dev/null || true
    wait "${SOCAT_PID}" 2>/dev/null || true
  fi
  if [[ -n "${CH_PID}" ]]; then
    kill "${CH_PID}" 2>/dev/null || true
    wait "${CH_PID}" 2>/dev/null || true
  fi
  if [[ -n "${DNSMASQ_PID}" ]]; then
    sudo kill "${DNSMASQ_PID}" 2>/dev/null || true
    wait "${DNSMASQ_PID}" 2>/dev/null || true
  fi
  sudo ip link del "$TAP_NAME" 2>/dev/null || true
  sudo ip link del "$BRIDGE_NAME" 2>/dev/null || true
}
trap cleanup EXIT

ssh_run() {
  sshpass -p "$WIN_PASS" ssh "${ssh_opts[@]}" cocoon@"$GUEST_IP" "$@"
}

ssh_run_timeout() {
  local timeout_s=$1
  shift
  timeout --foreground "$timeout_s" \
    sshpass -p "$WIN_PASS" ssh "${ssh_opts[@]}" cocoon@"$GUEST_IP" "$@"
}

scp_to_guest() {
  sshpass -p "$WIN_PASS" scp "${ssh_opts[@]}" "$@" cocoon@"$GUEST_IP":"C:/scripts/"
}

wait_for_ssh() {
  for _ in $(seq 1 60); do
    if ssh_run_timeout 15 "echo ok" 2>/dev/null | grep -q ok; then
      return 0
    fi
    sleep 5
  done
  return 1
}

wait_for_rdp() {
  for _ in $(seq 1 30); do
    if xfreerdp /v:127.0.0.1:3389 /u:cocoon /p:"$WIN_PASS" /auth-only /cert:ignore >/dev/null 2>&1; then
      return 0
    fi
    sleep 5
  done
  return 1
}

log "setting up bridge/tap + dnsmasq"
sudo ip link del "$TAP_NAME" 2>/dev/null || true
sudo ip link del "$BRIDGE_NAME" 2>/dev/null || true
sudo ip link add "$BRIDGE_NAME" type bridge
sudo ip addr add "$SUBNET_CIDR" dev "$BRIDGE_NAME"
sudo ip link set "$BRIDGE_NAME" up
sudo ip tuntap add "$TAP_NAME" mode tap user "$USER"
sudo ip link set "$TAP_NAME" master "$BRIDGE_NAME"
sudo ip link set "$TAP_NAME" up

cat >"$DNSMASQ_CONF" <<EOF
interface=$BRIDGE_NAME
bind-interfaces
port=0
dhcp-range=$DHCP_RANGE_START,$DHCP_RANGE_END,12h
dhcp-option=option:router,$ROUTER_IP
dhcp-option=option:dns-server,8.8.8.8,1.1.1.1
dhcp-leasefile=$LEASE_FILE
log-dhcp
log-facility=$DNSMASQ_LOG
EOF

sudo dnsmasq --keep-in-foreground --conf-file="$DNSMASQ_CONF" >"$DNSMASQ_STDERR" 2>&1 &
DNSMASQ_PID=$!
sleep 2

log "launching Cloud Hypervisor"
log "Cloud Hypervisor resources: cpus=$CH_CPU_COUNT memory=$CH_MEMORY_SIZE"
"$CLOUD_HYPERVISOR_BIN" \
  --api-socket "$API_SOCKET" \
  --log-file "$CH_LOG" \
  --firmware "$FIRMWARE_PATH" \
  --disk path="$QCOW2_PATH",image_type=qcow2,backing_files=on \
  --cpus boot="$CH_CPU_COUNT",kvm_hyperv=on \
  --memory size="$CH_MEMORY_SIZE" \
  --net tap="$TAP_NAME",mac="$GUEST_MAC" \
  --rng src=/dev/urandom \
  --serial socket="$SERIAL_SOCKET" \
  --console off &
CH_PID=$!

log "waiting for DHCPACK"
for _ in $(seq 1 120); do
  if [[ -s "$LEASE_FILE" ]]; then
    GUEST_IP=$(awk 'END { print $3 }' "$LEASE_FILE")
    break
  fi
  sleep 2
done

if [[ -z "${GUEST_IP}" ]]; then
  log "guest never acquired a DHCP lease"
  exit 1
fi

log "guest DHCP lease: $GUEST_IP"
sudo grep -q "DHCPACK.*COCOON-VM" "$DNSMASQ_LOG"

ping -c 4 "$GUEST_IP" | tee "$ARTIFACT_DIR/ping.log"

mkdir -p "$ARTIFACT_DIR"
ssh_run "if not exist C:\\scripts mkdir C:\\scripts" >/dev/null 2>&1 || true
scp_to_guest "$ROOT_DIR/scripts/verify.ps1" "$ROOT_DIR/scripts/remediate.ps1"

log "waiting for SSH"
wait_for_ssh
ssh_run_timeout "$SSH_COMMAND_TIMEOUT" "powershell -NoProfile -ExecutionPolicy Bypass -File C:\\scripts\\verify.ps1 -RequireSerialDevice" \
  | tee "$ARTIFACT_DIR/ch-guest-verify.log"

log "starting local RDP forward on the remote host"
socat TCP-LISTEN:3389,bind=127.0.0.1,reuseaddr,fork TCP:"$GUEST_IP":3389 \
  >"$ARTIFACT_DIR/rdp-forward.log" 2>&1 &
SOCAT_PID=$!

log "verifying RDP auth"
wait_for_rdp

log "probing SAC on COM1"
python3 "$ROOT_DIR/scripts/sac_probe.py" "$SERIAL_SOCKET" | tee "$ARTIFACT_DIR/sac-probe.log"

log "requesting clean shutdown over SSH"
ssh_run "shutdown /s /t 10" >/dev/null 2>&1 || true
for _ in $(seq 1 120); do
  if ! kill -0 "$CH_PID" 2>/dev/null; then
    CH_PID=""
    break
  fi
  sleep 1
done
if [[ -n "${CH_PID}" ]]; then
  log "Cloud Hypervisor did not exit after guest shutdown"
  exit 1
fi

printf '%s\n' "$GUEST_IP" >"$ARTIFACT_DIR/guest-ip.txt"
log "Cloud Hypervisor runtime verification passed"
