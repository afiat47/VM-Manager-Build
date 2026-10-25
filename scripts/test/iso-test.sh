#!/usr/bin/env bash
#
# End-to-end test of an ISO built with `./m.sh iso --unattended`: installs it in a QEMU VM
# that has NO internet access (user networking with restrict=on), then waits until VM Manager
# answers on port 30080 after the first-boot setup.
#
#   ./m.sh test-iso [path/to/vm-manager-...-unattended.iso]
#
# Needs /dev/kvm in the container engine (Docker Desktop with nestedVirtualization=true in
# .wslconfig, or a Linux host). The VM disk lives in cache/test-vm/ (sparse qcow2).
# While it runs:  VM Manager  http://localhost:30080     SSH  ssh -p 2222 vmm@localhost (password vmm)
#
set -euo pipefail

ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
# shellcheck source=../lib/common.sh
source "${ROOT_DIR}/scripts/lib/common.sh"
load_versions

ISO="${1:-$(ls -t "${ROOT_DIR}"/output/*-unattended.iso 2>/dev/null | head -n1)}"
[[ -n "${ISO}" && -f "${ISO}" ]] || die "no unattended ISO - build one with ./m.sh iso --unattended"
VM_DIR="${TEST_VM_DIR:-${ROOT_DIR}/cache/test-vm}"
VM_MEMORY="${TEST_VM_MEMORY:-7G}"
VM_CPUS="${TEST_VM_CPUS:-6}"
TIMEOUT_MIN="${TEST_TIMEOUT_MIN:-150}"
NAME="vm-manager-iso-test"

# The VM disk lives in a container volume (Linux storage): a disk image on a folder shared from
# Windows (Docker Desktop's 9p/drvfs) gets write errors under load.
DISK_VOLUME="${NAME}-disk"

require_cri
mkdir -p "${VM_DIR}"
rm -f "${VM_DIR}"/disk.qcow2 "${VM_DIR}"/*.log
cri rm -f "${NAME}" >/dev/null 2>&1 || true
cri volume rm -f "${DISK_VOLUME}" >/dev/null 2>&1 || true

log "Starting the test VM (${VM_CPUS} vCPUs, ${VM_MEMORY}, no internet) from $(basename "${ISO}")"
cri run -d --name "${NAME}" --device /dev/kvm \
    -p 127.0.0.1:30080:30080 -p 127.0.0.1:2222:2222 \
    -v "$(host_path "${ISO}"):/iso/test.iso:ro" \
    -v "$(host_path "${VM_DIR}"):/vm" \
    -v "${DISK_VOLUME}:/disk" \
    "${UBUNTU_TOOLS_IMAGE}" bash -c '
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get install -y -qq qemu-system-x86 qemu-utils ovmf curl sshpass socat >/dev/null
qemu-img create -f qcow2 /disk/disk.qcow2 120G >/dev/null
cp /usr/share/OVMF/OVMF_VARS_4M.fd /disk/OVMF_VARS.fd
# Safety net: if a disk write still fails, QEMU pauses the VM (werror=stop); resume it.
( while sleep 2; do
    if echo "info status" | socat - unix-connect:/tmp/monitor.sock 2>/dev/null | grep -q paused; then
      echo cont | socat - unix-connect:/tmp/monitor.sock >/dev/null 2>&1
      echo "$(date +%T) resumed" >>/vm/disk-retries.log
    fi
  done ) &
echo QEMU-STARTING
exec qemu-system-x86_64 -enable-kvm -cpu host -smp '"${VM_CPUS}"' -m '"${VM_MEMORY}"' \
    -machine q35 \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
    -drive if=pflash,format=raw,file=/disk/OVMF_VARS.fd \
    -drive file=/disk/disk.qcow2,if=virtio,cache=writeback,aio=threads,discard=ignore,detect-zeroes=off,werror=stop,rerror=stop \
    -cdrom /iso/test.iso -boot once=d \
    -nic user,model=virtio-net-pci,restrict=on,hostfwd=tcp::30080-:30080,hostfwd=tcp::2222-:22 \
    -vga std -display none -serial file:/vm/serial.log -monitor unix:/tmp/monitor.sock,server,nowait
' >/dev/null

until cri logs "${NAME}" 2>&1 | grep -q QEMU-STARTING; do
    cri ps -q -f name="${NAME}" | grep -q . || { cri logs "${NAME}"; die "the test container stopped"; }
    sleep 5
done
echo "QEMU is running. Install + first-boot setup usually take 30-60 minutes here."

vmssh() { cri exec "${NAME}" sshpass -p vmm ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR vmm@localhost -p 2222 "$@"; }
monitor() { cri exec "${NAME}" bash -c "echo '$1' | socat - unix-connect:/tmp/monitor.sock" 2>/dev/null; }

# The VM disk lives in a folder shared from the host; on Windows (Docker Desktop's 9p/drvfs
# share) writes occasionally fail. QEMU then pauses the VM (werror=stop) instead of handing the
# error to the guest, and this loop resumes it, which retries the write.
retries=0
start=$(date +%s)
phase=""
while true; do
    if monitor 'info status' | grep -q 'paused'; then
        monitor cont >/dev/null
        retries=$((retries + 1))
        echo "  host disk write failed, retried (${retries})"
    fi
    elapsed=$(( ($(date +%s) - start) / 60 ))
    ((elapsed < TIMEOUT_MIN)) || die "timeout after ${TIMEOUT_MIN} minutes (serial log: ${VM_DIR}/serial.log)"
    cri ps -q -f name="${NAME}" | grep -q . || die "QEMU stopped (serial log: ${VM_DIR}/serial.log)"
    if cri exec "${NAME}" curl -fsS -o /dev/null --max-time 5 http://localhost:30080/actuator/health/readiness 2>/dev/null; then
        log "VM Manager is up after ${elapsed} minutes - http://localhost:30080"
        break
    fi
    now="$(vmssh 'systemctl is-active vmm-firstboot 2>/dev/null; tail -n1 /var/log/vm-manager-install.log 2>/dev/null' 2>/dev/null | tr '\n' ' ' || true)"
    [[ -n "${now}" ]] || now="installing Ubuntu (no SSH yet)"
    if [[ "${now}" != "${phase}" ]]; then
        printf '  [%3d min] %s\n' "${elapsed}" "${now}"
        phase="${now}"
    fi
    if [[ "${now}" == failed* ]]; then
        vmssh 'echo vmm | sudo -S tail -n 40 /var/log/vm-manager-install.log' || true
        die "first-boot setup failed"
    fi
    sleep 15
done

log "Cluster state in the test VM"
vmssh 'echo vmm | sudo -S -p "" kubectl get nodes -o wide; echo vmm | sudo -S -p "" kubectl get pods -A --no-headers | awk "{print \$1, \$2, \$4}" | column -t'
echo
echo "The VM keeps running. Stop it with: docker rm -f ${NAME}"
