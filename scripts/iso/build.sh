#!/usr/bin/env bash
#
# Build the VM Manager installer ISO: the official Ubuntu Server ISO (versions.env) plus
#   /vmm/                 the bundle from ./m.sh bundle (copied to /opt/vm-manager)
#   /vmm-iso/             late-install.sh, the first-boot service and the vmm-* commands
#   /autoinstall.yaml     unattended install; asks only network, disk and hostname/user
#   /boot/grub/grub.cfg   boot menu: "first server" or "join existing cluster"
#
# The Ubuntu ISO is downloaded once into cache/ubuntu/ and checked against UBUNTU_ISO_SHA256.
# Use your own copy with UBUNTU_ISO=/path/to/ubuntu-...-live-server-amd64.iso (also checked).
#
# Output: output/vm-manager-<version>-<bundle id>.iso (+ .sha256)
#
set -euo pipefail

ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
# shellcheck source=../lib/common.sh
source "${ROOT_DIR}/scripts/lib/common.sh"
load_versions

BUNDLE_DIR="${BUNDLE_DIR:-${ROOT_DIR}/bundle}"
FILES_DIR="${ROOT_DIR}/scripts/iso/files"
OUT_DIR="${ISO_OUT_DIR:-${ROOT_DIR}/output}"
UBUNTU_ISO="${UBUNTU_ISO:-${ROOT_DIR}/cache/ubuntu/$(basename "${UBUNTU_ISO_URL}")}"
UNATTENDED=false

usage() {
    cat <<EOF
Usage: ./m.sh iso [--unattended]

Builds ${OUT_DIR#"${ROOT_DIR}/"}/vm-manager-<version>-<bundle id>.iso from Ubuntu Server ${UBUNTU_RELEASE} and ${BUNDLE_DIR#"${ROOT_DIR}/"}/.

  --unattended   Ask nothing at all: DHCP network, the whole first disk, hostname vmm-server,
                 user vmm / password vmm. Meant for test VMs only.

Variables: UBUNTU_ISO (use your own downloaded ISO; its SHA256 is checked), ISO_OUT_DIR.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
    --unattended) UNATTENDED=true ;;
    -h | --help)
        usage
        exit 0
        ;;
    *) die "unknown option '$1' (see ./m.sh iso --help)" ;;
    esac
    shift
done

require_cri
[[ -f "${BUNDLE_DIR}/bundle-id" ]] || die "no bundle in ${BUNDLE_DIR} - run ./m.sh bundle first"
bundle_id="$(tr -d '\r\n' <"${BUNDLE_DIR}/bundle-id")"

# ---------------------------------------------------------------------------
# 1. The Ubuntu ISO, checksum verified
# ---------------------------------------------------------------------------
if [[ ! -f "${UBUNTU_ISO}" ]]; then
    log "Downloading Ubuntu Server ${UBUNTU_RELEASE}"
    mkdir -p "$(dirname "${UBUNTU_ISO}")"
    curl -fL --retry 5 -C - -o "${UBUNTU_ISO}.part" "${UBUNTU_ISO_URL}"
    mv -f "${UBUNTU_ISO}.part" "${UBUNTU_ISO}"
fi
log "Verifying $(basename "${UBUNTU_ISO}")"
echo "${UBUNTU_ISO_SHA256} *${UBUNTU_ISO}" | sha256sum -c --quiet - ||
    die "${UBUNTU_ISO} does not match UBUNTU_ISO_SHA256 in versions.env (wrong or corrupted file)"

# ---------------------------------------------------------------------------
# 2. Boot menu + autoinstall
# ---------------------------------------------------------------------------
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
mkdir -p "${work}/vmm-iso" "${OUT_DIR}"
cp "${FILES_DIR}"/{late-install.sh,vmm-firstboot,vmm-firstboot.service,vmm-install,vmm-join} "${work}/vmm-iso/"
cp "${FILES_DIR}/autoinstall.yaml" "${work}/autoinstall.yaml"
if [[ "${UNATTENDED}" == true ]]; then
    warn "unattended ISO: test VMs only (fixed user vmm / password vmm, erases the first disk)"
    # Replace the interactive sections with fixed answers.
    sed -i '/interactive-sections:/,/- identity/d' "${work}/autoinstall.yaml"
    cat >>"${work}/autoinstall.yaml" <<'EOF'
  network:
    version: 2
    ethernets:
      any:
        match: {name: "e*"}
        dhcp4: true
  storage:
    layout:
      name: lvm
      sizing-policy: all
  identity:
    hostname: vmm-server
    username: vmm
    # "vmm"
    password: "$6$vmmtest$5gRp.ndInoD9qEy82ie2GV8Kn4oS9C6Hi9LLu3FBvQorjtbKFHdKleGC3unmcFCJNvAXMIIB3nwV2HM1DvIiH/"
EOF
fi
for f in "${work}"/vmm-iso/* "${work}/autoinstall.yaml"; do
    [[ "$(tr -cd '\r' <"${f}" | wc -c)" -eq 0 ]] || sed -i 's/\r$//' "${f}"
done

iso_name="vm-manager-${VM_MANAGER_VERSION}-${bundle_id}"
[[ "${UNATTENDED}" == true ]] && iso_name="${iso_name}-unattended"

log "Building ${iso_name}.iso (the bundle is $(du -sh "${BUNDLE_DIR}" | cut -f1))"
tr -d '\r' <<'XORRISO' | cri run --rm -i \
    -v "$(host_path "${UBUNTU_ISO}"):/in/ubuntu.iso:ro" \
    -v "$(host_path "${BUNDLE_DIR}"):/in/bundle:ro" \
    -v "$(host_path "${work}"):/in/files:ro" \
    -v "$(host_path "${OUT_DIR}"):/out" \
    -e "ISO_NAME=${iso_name}" \
    -e "RELEASE=${UBUNTU_RELEASE}" \
    "${UBUNTU_TOOLS_IMAGE}" bash -s
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get install -y -qq xorriso >/dev/null

# The original boot menu, with two VM Manager entries in front of it.
xorriso -osirrox on -indev /in/ubuntu.iso -extract /boot/grub/grub.cfg /tmp/grub.orig >/dev/null 2>&1
chmod u+w /tmp/grub.orig
entry() {   # <title> <role>
    cat <<EOF
menuentry "$1" {
	set gfxpayload=keep
	linux	/casper/vmlinuz autoinstall vmm.role=$2 ---
	initrd	/casper/initrd
}
EOF
}
{
    echo "set default=0"
    echo "set timeout=30"
    echo
    entry "Install VM Manager - first server (new cluster)" create
    entry "Install VM Manager - join an existing cluster" join
    # The original file minus its own default/timeout settings.
    grep -vE '^[[:space:]]*set (default|timeout)=' /tmp/grub.orig
} >/tmp/grub.cfg

# Modify the ISO in place: new files mapped in, Ubuntu's boot setup (BIOS + UEFI) replayed.
rm -f "/out/${ISO_NAME}.iso"
xorriso -indev /in/ubuntu.iso -outdev "/out/${ISO_NAME}.iso" \
    -map /in/bundle /vmm \
    -map /in/files/vmm-iso /vmm-iso \
    -map /in/files/autoinstall.yaml /autoinstall.yaml \
    -map /tmp/grub.cfg /boot/grub/grub.cfg \
    -boot_image any replay 2>&1 | grep -vE 'UPDATE :|^xorriso : (NOTE|UPDATE)' || true
[ -s "/out/${ISO_NAME}.iso" ] || { echo "xorriso produced no ISO" >&2; exit 1; }
cd /out && sha256sum "${ISO_NAME}.iso" >"${ISO_NAME}.iso.sha256"
XORRISO

log "ISO ready"
ls -lh "${OUT_DIR}/${iso_name}.iso" | awk '{print "  " $NF "  (" $5 ")"}'
echo "  checksum: $(cut -d' ' -f1 "${OUT_DIR}/${iso_name}.iso.sha256")"
echo
echo "Write it to a USB stick (e.g. Rufus in DD mode, balenaEtcher, or dd on Linux) and boot the server."
