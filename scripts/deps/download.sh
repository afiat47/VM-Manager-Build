#!/usr/bin/env bash
#
# Download everything the ISO needs that is not built from apps/, at the versions pinned in
# versions.env, into cache/deps/:
#
#   debs/        Ubuntu + Kubernetes .deb packages with all dependencies, as a local apt
#                repository (Packages.gz). Ubuntu packages come from snapshot.ubuntu.com at
#                UBUNTU_SNAPSHOT, Kubernetes packages from pkgs.k8s.io at exactly K8S_VERSION.
#   bin/         containerd, runc and containerd.service (checksums verified)
#   manifests/   Calico, Multus, metrics-server, CDI and snapshot-controller YAMLs
#   images/      one `docker save` tar per image (linux/amd64)
#   images.txt   every image in images/
#
# Image digests are pinned in versions.lock. `./m.sh deps --lock` (re)creates it from the tags;
# a normal run downloads exactly the locked digests and fails on images missing from the lock.
#
set -euo pipefail

ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
# shellcheck source=../lib/common.sh
source "${ROOT_DIR}/scripts/lib/common.sh"
load_versions

DEPS_DIR="${DEPS_DIR:-${ROOT_DIR}/cache/deps}"
LOCK_FILE="${ROOT_DIR}/versions.lock"
PLATFORM="linux/amd64"
ROOK_SRC="${ROOK_SRC:-${ROOT_DIR}/apps/rook}"

# Calico 3.33 images needed by the operator-based install in install.sh (VXLAN, APIServer).
# Optional Calico features (Whisker, Envoy gateway, Istio) are not bundled.
CALICO_IMAGES="calico node third-party-cni-plugins"

# Packages install.sh installs, beyond what Ubuntu Server already has. Kubernetes packages
# are pinned to K8S_VERSION below; containerd/runc come from bin/ (Kubernetes 1.36 needs
# containerd >= 2.0, newer than Ubuntu 24.04's package).
APT_PACKAGES="curl jq gpg ca-certificates lvm2 open-iscsi nfs-common qemu-utils conntrack socat ethtool ebtables iptables"

usage() {
    cat <<EOF
Usage: ./m.sh deps [--lock]

Downloads the pinned third-party dependencies into ${DEPS_DIR#"${ROOT_DIR}/"}/.

  --lock    Resolve every image tag to its current digest and write versions.lock.
            Run it once after changing versions.env; normal runs use the locked digests.
EOF
}

LOCK=false
while [[ $# -gt 0 ]]; do
    case "$1" in
    --lock) LOCK=true ;;
    -h | --help)
        usage
        exit 0
        ;;
    *) die "unknown option '$1' (see ./m.sh deps --help)" ;;
    esac
    shift
done

require_cri
command -v curl >/dev/null 2>&1 || die "curl is required"
mkdir -p "${DEPS_DIR}"/{debs,bin,manifests,images}

fetch() {   # <url> <dest>
    curl -fsSL --retry 3 -o "$2.part" "$1" || die "download failed: $1"
    mv -f "$2.part" "$2"
}

# ---------------------------------------------------------------------------
# 1. Manifests (pinned URLs), with upstream tags fixed to the pinned versions
# ---------------------------------------------------------------------------
log "Downloading manifests"
M="${DEPS_DIR}/manifests"
mkdir -p "${M}"/{calico,multus,metrics-server,cdi,snapshotter}
fetch "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/tigera-operator.yaml" "${M}/calico/tigera-operator.yaml"
fetch "https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/${MULTUS_VERSION}/deployments/multus-daemonset-thick.yml" "${M}/multus/multus-daemonset-thick.yml"
fetch "https://github.com/kubernetes-sigs/metrics-server/releases/download/${METRICS_SERVER_VERSION}/components.yaml" "${M}/metrics-server/components.yaml"
fetch "https://github.com/kubevirt/containerized-data-importer/releases/download/${CDI_VERSION}/cdi-operator.yaml" "${M}/cdi/cdi-operator.yaml"
fetch "https://github.com/kubevirt/containerized-data-importer/releases/download/${CDI_VERSION}/cdi-cr.yaml" "${M}/cdi/cdi-cr.yaml"
snap="https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/${SNAPSHOTTER_VERSION}"
for crd in snapshot.storage.k8s.io_volumesnapshotclasses snapshot.storage.k8s.io_volumesnapshotcontents snapshot.storage.k8s.io_volumesnapshots; do
    fetch "${snap}/client/config/crd/${crd}.yaml" "${M}/snapshotter/${crd}.yaml"
done
fetch "${snap}/deploy/kubernetes/snapshot-controller/rbac-snapshot-controller.yaml" "${M}/snapshotter/rbac-snapshot-controller.yaml"
fetch "${snap}/deploy/kubernetes/snapshot-controller/setup-snapshot-controller.yaml" "${M}/snapshotter/setup-snapshot-controller.yaml"

# Multus' release manifest points at the moving "snapshot-thick" tag, and the snapshotter's
# at an older controller; pin both to the release they belong to.
sed -i "s|\(image: ghcr.io/k8snetworkplumbingwg/multus-cni\):snapshot-thick|\1:${MULTUS_VERSION}-thick|" "${M}/multus/multus-daemonset-thick.yml"
sed -i "s|\(image: registry.k8s.io/sig-storage/snapshot-controller\):v[0-9.]*|\1:${SNAPSHOTTER_VERSION}|" "${M}/snapshotter/setup-snapshot-controller.yaml"
# The Multus daemon handles every pod start on its server (each VM is a pod); upstream's limits
# (100m CPU, 50Mi) throttle it until pod network setup times out on a busy server.
sed -i -E '/^[[:space:]]+limits:$/,/memory:/ { s/cpu: "100m"/cpu: "2"/; s/memory: "50Mi"/memory: "500Mi"/ }' "${M}/multus/multus-daemonset-thick.yml"
grep -q 'memory: "500Mi"' "${M}/multus/multus-daemonset-thick.yml" || die "could not raise the Multus daemon limits (manifest layout changed?)"

# ---------------------------------------------------------------------------
# 2. containerd + runc (official static builds, checksums verified)
# ---------------------------------------------------------------------------
log "Downloading containerd ${CONTAINERD_VERSION} and runc ${RUNC_VERSION}"
B="${DEPS_DIR}/bin"
ctd="containerd-${CONTAINERD_VERSION}-linux-amd64.tar.gz"
if [[ ! -f "${B}/${ctd}" ]]; then
    fetch "https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/${ctd}" "${B}/${ctd}"
    fetch "https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/${ctd}.sha256sum" "${B}/${ctd}.sha256sum"
fi
(cd "${B}" && sha256sum -c --quiet "${ctd}.sha256sum") || die "checksum mismatch: ${ctd}"
fetch "https://raw.githubusercontent.com/containerd/containerd/v${CONTAINERD_VERSION}/containerd.service" "${B}/containerd.service"
if [[ ! -f "${B}/runc.amd64" ]]; then
    fetch "https://github.com/opencontainers/runc/releases/download/v${RUNC_VERSION}/runc.amd64" "${B}/runc.amd64"
    fetch "https://github.com/opencontainers/runc/releases/download/v${RUNC_VERSION}/runc.sha256sum" "${B}/runc.sha256sum"
fi
(cd "${B}" && grep ' runc.amd64$' runc.sha256sum | sha256sum -c --quiet -) || die "checksum mismatch: runc.amd64"

# ---------------------------------------------------------------------------
# 3. .deb packages (local apt repository) + the Kubernetes system image list
# ---------------------------------------------------------------------------
log "Downloading .deb packages (Ubuntu snapshot ${UBUNTU_SNAPSHOT}, Kubernetes ${K8S_VERSION})"
rm -rf "${DEPS_DIR}/debs"
mkdir -p "${DEPS_DIR}/debs"
tr -d '\r' <<'APT' | cri run --rm -i \
    -v "$(host_path "${DEPS_DIR}/debs"):/out" \
    -e "SNAPSHOT=${UBUNTU_SNAPSHOT}" \
    -e "K8S_VERSION=${K8S_VERSION}" \
    -e "PACKAGES=${APT_PACKAGES}" \
    "${UBUNTU_TOOLS_IMAGE}" bash -s
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
minor="v$(echo "${K8S_VERSION#v}" | cut -d. -f1,2)"

# Tools for this container only (HTTPS, keys, repository index), from the image's default
# sources; none of these end up in the bundle.
apt-get update -qq
apt-get install -y -qq ca-certificates curl gpg dpkg-dev >/dev/null
# Everything downloaded for the bundle comes from the Ubuntu archive frozen at SNAPSHOT.
cat >/etc/apt/sources.list.d/ubuntu.sources <<EOF
Types: deb
URIs: https://snapshot.ubuntu.com/ubuntu/${SNAPSHOT}
Suites: noble noble-updates noble-security
Components: main restricted universe
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
mkdir -p /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${minor}/deb/Release.key" | gpg --dearmor -o /etc/apt/keyrings/kubernetes.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes.gpg] https://pkgs.k8s.io/core:/stable:/${minor}/deb/ /" >/etc/apt/sources.list.d/kubernetes.list
apt-get -o Acquire::Check-Valid-Until=false update -qq

kver="$(apt-cache madison kubeadm | awk -v v="${K8S_VERSION#v}" '$3 ~ "^"v"-" {print $3; exit}')"
[ -n "${kver}" ] || { echo "kubeadm ${K8S_VERSION} not found on pkgs.k8s.io" >&2; exit 1; }
echo "Kubernetes packages: ${kver}"

# Full dependency closure (also packages Ubuntu Server already has), so apt on the device
# never needs anything that isn't in the bundle, whatever is installed there.
want="kubeadm=${kver} kubelet=${kver} kubectl=${kver} cri-tools kubernetes-cni ${PACKAGES}"
names="$(apt-cache depends --recurse --no-recommends --no-suggests --no-conflicts --no-breaks \
    --no-replaces --no-enhances kubeadm kubelet kubectl cri-tools kubernetes-cni ${PACKAGES} |
    grep -E '^[a-z0-9]' | sort -u)"
real=""
for n in ${names}; do
    # Skip virtual packages (no versions of their own).
    if apt-cache show "${n}" >/dev/null 2>&1; then real="${real} ${n}"; fi
done
cd /out
apt-get download -qq ${real} >/dev/null 2>&1 || true
# Pinned Kubernetes versions (the closure above downloaded the latest of the minor).
rm -f kubeadm_* kubelet_* kubectl_*
apt-get download -qq ${want%% cri-tools*} >/dev/null
# Every requested package must be present.
for p in kubeadm kubelet kubectl cri-tools kubernetes-cni ${PACKAGES}; do
    ls "${p}"_*.deb >/dev/null 2>&1 || { echo "missing package: ${p}" >&2; exit 1; }
done
dpkg-scanpackages -m . /dev/null 2>/dev/null | gzip -9 >Packages.gz
echo "${kver}" >kubernetes-deb-version
echo "$(ls *.deb | wc -l) packages, $(du -sh . | cut -f1)"

# The control-plane images this kubeadm uses.
dpkg -x kubeadm_*.deb /tmp/kubeadm
/tmp/kubeadm/usr/bin/kubeadm config images list --kubernetes-version "${K8S_VERSION}" >/out/k8s-images.txt
APT
mv -f "${DEPS_DIR}/debs/k8s-images.txt" "${DEPS_DIR}/k8s-images.txt"

# ---------------------------------------------------------------------------
# 4. Image list
# ---------------------------------------------------------------------------
log "Collecting the image list"
yaml_images() {   # image: lines and *_IMAGE env values in the given YAMLs
    grep -hE '^[[:space:]]*(- )?image:[[:space:]]|^[[:space:]]*value:[[:space:]]*[a-z0-9.-]+\.[a-z]+/.+:[^[:space:]]+$' "$@" |
        awk '{print $NF}' | tr -d '"'"'"
}
{
    cat "${DEPS_DIR}/k8s-images.txt"
    yaml_images "${M}/calico/tigera-operator.yaml"
    for i in ${CALICO_IMAGES}; do echo "quay.io/calico/${i}:${CALICO_VERSION}"; done
    yaml_images "${M}/multus/multus-daemonset-thick.yml"
    yaml_images "${M}/metrics-server/components.yaml"
    yaml_images "${M}/snapshotter/setup-snapshot-controller.yaml"
    yaml_images "${M}/cdi/cdi-operator.yaml"
    # Everything Rook deploys besides its own operator (built by ./m.sh rook), from the pinned tag.
    hgit -C "${ROOK_SRC}" show "${ROOK_VERSION}:deploy/examples/images.txt" | grep -v '/rook/ceph:'
    echo "${CEPH_IMAGE}"
    echo "${POSTGRES_IMAGE}"
    echo "${AGENT_IMAGE}"
} | tr -d '\r' | grep -v '^[[:space:]]*$' | sort -u >"${DEPS_DIR}/images.txt"
grep -nE ':(latest|snapshot[^ ]*)$|^[^:]+$' "${DEPS_DIR}/images.txt" &&
    die "moving or missing tags in the image list (see above); pin them in versions.env"
echo "$(wc -l <"${DEPS_DIR}/images.txt") images"

# ---------------------------------------------------------------------------
# 5. Digests (versions.lock)
# ---------------------------------------------------------------------------
digest_of() { grep -F -- "$1 " "${LOCK_FILE}" 2>/dev/null | awk '{print $2}' | head -n1; }
if [[ "${LOCK}" == true || ! -f "${LOCK_FILE}" ]]; then
    log "Resolving image digests into versions.lock"
    {
        echo "# Image digests for versions.env, written by ./m.sh deps --lock on $(date -u +%Y-%m-%d)."
        echo "# Normal runs download exactly these; re-run --lock only after changing versions.env."
        while read -r ref; do
            d="$(cri buildx imagetools inspect "${ref}" --format '{{.Manifest.Digest}}' 2>/dev/null | tr -d '[:space:]')"
            [[ "${d}" == sha256:* ]] || die "cannot resolve ${ref}"
            echo "${ref} ${d}"
            printf '  %-70s %s\n' "${ref}" "${d:0:19}" >&2
        done <"${DEPS_DIR}/images.txt"
    } >"${LOCK_FILE}.new"
    mv -f "${LOCK_FILE}.new" "${LOCK_FILE}"
fi
missing="$(while read -r ref; do [[ -n "$(digest_of "${ref}")" ]] || echo "${ref}"; done <"${DEPS_DIR}/images.txt")"
[[ -z "${missing}" ]] || die "not in versions.lock (run ./m.sh deps --lock):
${missing}"

# ---------------------------------------------------------------------------
# 6. Pull + save every image (exactly the locked digest)
# ---------------------------------------------------------------------------
log "Downloading images"
I="${DEPS_DIR}/images"
keep=""
while read -r ref; do
    digest="$(digest_of "${ref}")"
    name="$(printf '%s' "${ref}" | tr '/:@' '___')"
    keep="${keep} ${name}.tar"
    if [[ -f "${I}/${name}.tar" && "$(cat "${I}/${name}.digest" 2>/dev/null)" == "${digest}" ]]; then
        printf '  %-70s cached\n' "${ref}"
        continue
    fi
    printf '  %-70s %s\n' "${ref}" "${digest:0:19}"
    repo="${ref%:*}"
    cri pull -q --platform "${PLATFORM}" "${repo}@${digest}" >/dev/null
    cri tag "${repo}@${digest}" "${ref}"
    cri save --platform "${PLATFORM}" -o "$(host_path "${I}/${name}.tar")" "${ref}"
    echo "${digest}" >"${I}/${name}.digest"
    cri rmi "${ref}" "${repo}@${digest}" >/dev/null 2>&1 || true
done <"${DEPS_DIR}/images.txt"
# Drop tars of images no longer in the list.
for f in "${I}"/*.tar; do
    [[ -e "${f}" ]] || continue
    case " ${keep} " in *" $(basename "${f}") "*) ;; *) rm -f "${f}" "${f%.tar}.digest" ;; esac
done

log "Dependencies ready in ${DEPS_DIR}"
du -sh "${DEPS_DIR}"/{debs,bin,images} | sed 's/^/  /'
