#!/usr/bin/env bash
#
# Collect every build output into bundle/: the complete, offline installation set that the ISO
# copies to /opt/vm-manager. It can also be copied to an existing Ubuntu 24.04 server by hand:
#   sudo /opt/vm-manager/vm-manager/installer/install.sh create
#
# Nothing is built or downloaded here. The bundle is refused when anything is missing or
# inconsistent: a manifest that references an image which is not in the bundle, a build whose
# version differs from versions.env, or a shell script with Windows line endings.
#
# Layout:
#   versions.env versions.lock versions.txt bundle-id
#   images/ images.txt k8s-images.txt     every container image (`docker save` tars)
#   debs/ bin/                            apt repository; containerd + runc
#   manifests/<component>/                calico multus metrics-server cdi snapshotter kubevirt rook
#   vm-manager/{deploy,installer}         VM Manager's deploy files and install.sh
#
set -euo pipefail

ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
# shellcheck source=../lib/common.sh
source "${ROOT_DIR}/scripts/lib/common.sh"
load_versions

BUNDLE_DIR="${BUNDLE_DIR:-${ROOT_DIR}/bundle}"
DEPS_DIR="${DEPS_DIR:-${ROOT_DIR}/cache/deps}"
IMG="${ROOT_DIR}/docker/images"
MAN="${ROOT_DIR}/manifests"

case "${1:-}" in
-h | --help)
    sed -n '3,19p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
"") ;;
*) die "unknown option '$1' (see ./m.sh bundle --help)" ;;
esac

# ---------------------------------------------------------------------------
# 1. Everything needed must have been built / downloaded
# ---------------------------------------------------------------------------
log "Checking build outputs"
need() {   # <path> <command that produces it>
    [[ -e "$1" ]] || die "missing ${1#"${ROOT_DIR}/"} - run $2 first"
}
need "${IMG}/kubevirt/build-info.txt" "./m.sh kubevirt"
need "${MAN}/kubevirt/kubevirt-operator.yaml" "./m.sh kubevirt"
need "${MAN}/kubevirt/kubevirt-cr.yaml" "./m.sh kubevirt"
# KubeVirt >= 1.9 deploys virt-template; its images (and their version) must come with the build.
if grep -q 'virt-template' "${MAN}/kubevirt/kubevirt-operator.yaml"; then
    need "${MAN}/kubevirt/virt-template-version" "./m.sh kubevirt (this KubeVirt deploys virt-template)"
fi
need "${IMG}/rook/build-info.txt" "./m.sh rook"
need "${MAN}/rook/operator.yaml" "./m.sh rook"
need "${IMG}/vm-manager/build-info.txt" "./m.sh vm-manager"
need "${MAN}/vm-manager/installer/install.sh" "./m.sh vm-manager"
need "${DEPS_DIR}/images.txt" "./m.sh deps"
need "${DEPS_DIR}/debs/Packages.gz" "./m.sh deps"
need "${DEPS_DIR}/k8s-images.txt" "./m.sh deps"
need "${ROOT_DIR}/versions.lock" "./m.sh deps --lock"

# Each build must be of the version pinned in versions.env (local changes on top are allowed,
# they show as -dirty / -N-g<commit>).
check_build() {   # <build-info.txt> <expected version>
    local name tag commit
    read -r name tag commit <"$1"
    case "${tag}" in
    "$2" | "$2"-*) ;;
    *) die "${name} was built as ${tag}, but versions.env pins $2 - rebuild it (./m.sh ${name})" ;;
    esac
    [[ "${tag}" == "$2" ]] || warn "${name} ${tag}: built from changes on top of $2"
    printf '  %-12s %-28s %s\n' "${name}" "${tag}" "${commit:0:12}"
}
check_build "${IMG}/kubevirt/build-info.txt" "${KUBEVIRT_VERSION}"
check_build "${IMG}/rook/build-info.txt" "${ROOK_VERSION}"
check_build "${IMG}/vm-manager/build-info.txt" "${VM_MANAGER_VERSION}"

# ---------------------------------------------------------------------------
# 2. Assemble (hard links where the filesystem allows, so the GBs aren't copied twice)
# ---------------------------------------------------------------------------
log "Assembling ${BUNDLE_DIR}"
rm -rf "${BUNDLE_DIR}"
mkdir -p "${BUNDLE_DIR}"/{images,manifests,vm-manager}
link() { cp -l "$@" 2>/dev/null || cp "$@"; }

link "${DEPS_DIR}"/images/*.tar "${BUNDLE_DIR}/images/"
for app in kubevirt rook vm-manager; do
    for t in "${IMG}/${app}"/*.tar; do
        link "${t}" "${BUNDLE_DIR}/images/${app}--$(basename "${t}")"
    done
done
cp -r "${DEPS_DIR}/debs" "${DEPS_DIR}/bin" "${BUNDLE_DIR}/"
cp "${DEPS_DIR}/k8s-images.txt" "${BUNDLE_DIR}/"
cp -r "${DEPS_DIR}"/manifests/. "${BUNDLE_DIR}/manifests/"
mkdir -p "${BUNDLE_DIR}/manifests/kubevirt" "${BUNDLE_DIR}/manifests/rook"
cp "${MAN}/kubevirt/kubevirt-operator.yaml" "${MAN}/kubevirt/kubevirt-cr.yaml" "${BUNDLE_DIR}/manifests/kubevirt/"
cp "${MAN}"/rook/*.yaml "${BUNDLE_DIR}/manifests/rook/"
cp -r "${MAN}/vm-manager/deploy" "${MAN}/vm-manager/installer" "${BUNDLE_DIR}/vm-manager/"
tr -d '\r' <"${ROOT_DIR}/versions.env" >"${BUNDLE_DIR}/versions.env"
tr -d '\r' <"${ROOT_DIR}/versions.lock" >"${BUNDLE_DIR}/versions.lock"

# ---------------------------------------------------------------------------
# 3. Image names, read from inside the tars (what `ctr images import` will create)
# ---------------------------------------------------------------------------
log "Reading image names from the tarballs"
# Fully qualified name, as containerd stores it (docker.io/library/... for short names).
normalize() {
    local r="${1%%@*}" first
    first="${r%%/*}"
    if [[ "${r}" != */* ]]; then
        r="docker.io/library/${r}"
    elif [[ "${first}" != *.* && "${first}" != *:* && "${first}" != localhost ]]; then
        r="docker.io/${r}"
    fi
    printf '%s\n' "${r}"
}
: >"${BUNDLE_DIR}/images.txt"
for t in "${BUNDLE_DIR}"/images/*.tar; do
    # JSON may be pretty-printed over several lines: join it first.
    names="$(tar -xOf "${t}" index.json 2>/dev/null | tr -d '\n' |
        grep -o '"io.containerd.image.name": *"[^"]*"' | sed 's/.*: *"\(.*\)"/\1/' || true)"
    if [[ -z "${names}" ]]; then
        # "RepoTags": [ "a:1", "b:2" ]  ->  a:1 b:2
        names="$(tar -xOf "${t}" manifest.json 2>/dev/null | tr -d '\n' | grep -o '"RepoTags": *\[[^]]*\]' |
            sed 's/^[^[]*\[\(.*\)\]$/\1/' | tr ',' '\n' | tr -d '" \t' | grep -v '^$' || true)"
    fi
    [[ -n "${names}" ]] || die "$(basename "${t}") has no image name (neither index.json nor manifest.json)"
    for n in ${names}; do normalize "${n}" >>"${BUNDLE_DIR}/images.txt"; done
done
sort -u -o "${BUNDLE_DIR}/images.txt" "${BUNDLE_DIR}/images.txt"
echo "$(wc -l <"${BUNDLE_DIR}/images.txt") images in $(ls "${BUNDLE_DIR}"/images/*.tar | wc -l) tarballs"

# ---------------------------------------------------------------------------
# 4. Every image the cluster will run must be in the bundle
# ---------------------------------------------------------------------------
log "Checking that every referenced image is bundled"
yaml_refs() {
    grep -rhE '^[[:space:]]*(- )?image:[[:space:]]|^[[:space:]]*value:[[:space:]]*[a-z0-9.-]+\.[a-z]+/[^[:space:]]+:[^[:space:]]+$' \
        --include='*.yaml' --include='*.yml' "$@" | awk '{print $NF}' | tr -d '"'"'" |
        grep -v '{{' | grep ':'
}
{
    yaml_refs "${BUNDLE_DIR}/manifests" "${BUNDLE_DIR}/vm-manager/deploy" | grep -v '^vm-manager:'
    # app.yaml names vm-manager:<any>; kustomize deploys it with the kustomization's newTag.
    echo "vm-manager:$(awk '/^[[:space:]]*newTag:/ {print $2; exit}' "${BUNDLE_DIR}/vm-manager/deploy/vm-manager/kustomization.yaml")"
    cat "${BUNDLE_DIR}/k8s-images.txt"
    # Created at runtime, not named in any manifest:
    # - KubeVirt components, deployed by virt-operator with its own prefix and tag
    op="$(awk '/^[[:space:]]*image:/ && /virt-operator/ {print $2; exit}' "${BUNDLE_DIR}/manifests/kubevirt/kubevirt-operator.yaml")"
    for c in virt-api virt-controller virt-handler virt-launcher virt-exportserver virt-exportproxy virt-synchronization-controller; do
        echo "${op/virt-operator/${c}}"
    done
    # - virt-template (KubeVirt >= 1.9): same prefix, but its own version
    if [[ -f "${MAN}/kubevirt/virt-template-version" ]]; then
        vt="$(tr -d '\r\n' <"${MAN}/kubevirt/virt-template-version")"
        for c in virt-template-apiserver virt-template-controller; do
            echo "${op%%/virt-operator:*}/${c}:${vt}"
        done
    fi
    # - Calico components, deployed by the tigera operator
    for c in calico node third-party-cni-plugins; do echo "quay.io/calico/${c}:${CALICO_VERSION}"; done
    # - Ceph CSI and Ceph itself, deployed by the Rook operator
    cat "${MAN}/rook/upstream-images.txt"
    # - The host agent DaemonSet, created by the VM Manager backend
    echo "${AGENT_IMAGE}"
} | tr -d '\r' | sort -u | while read -r ref; do
    [[ -n "${ref}" ]] || continue
    n="$(normalize "${ref}")"
    if grep -qxF "${n}" "${BUNDLE_DIR}/images.txt"; then
        printf '  ok       %s\n' "${n}"
    else
        printf '  MISSING  %s\n' "${n}"
    fi
done | tee "${BUNDLE_DIR}/.image-check" | grep -c '^  ok' | xargs printf '  %s referenced images found\n'
if grep -q MISSING "${BUNDLE_DIR}/.image-check"; then
    grep MISSING "${BUNDLE_DIR}/.image-check" >&2
    die "the bundle would not install offline: images above are referenced but not bundled"
fi
rm -f "${BUNDLE_DIR}/.image-check"

# ---------------------------------------------------------------------------
# 5. Scripts must run on Linux
# ---------------------------------------------------------------------------
while IFS= read -r -d '' f; do
    [[ "$(tr -cd '\r' <"${f}" | wc -c)" -eq 0 ]] || die "${f#"${BUNDLE_DIR}/"} has Windows (CRLF) line endings"
    bash -n "${f}" || die "${f#"${BUNDLE_DIR}/"} has a syntax error"
done < <(find "${BUNDLE_DIR}" -name '*.sh' -print0)

# ---------------------------------------------------------------------------
# 6. Version record
# ---------------------------------------------------------------------------
{
    echo "VM Manager installation bundle, assembled $(date -u +'%Y-%m-%d %H:%M UTC')"
    echo
    echo "Built from apps/ (name, tag, source commit):"
    cat "${IMG}"/{kubevirt,rook,vm-manager}/build-info.txt | sed 's/^/  /'
    echo
    echo "Pinned versions (versions.env):"
    grep -E '^[A-Z_]+=' "${BUNDLE_DIR}/versions.env" | sed 's/^/  /'
    echo
    echo "Kubernetes packages: $(cat "${BUNDLE_DIR}/debs/kubernetes-deb-version")"
} >"${BUNDLE_DIR}/versions.txt"
(cd "${BUNDLE_DIR}" && find . -type f ! -name bundle-id -printf '%P %s\n' | sort | sha256sum | cut -c1-16) >"${BUNDLE_DIR}/bundle-id"

log "Bundle $(cat "${BUNDLE_DIR}/bundle-id") ready: ${BUNDLE_DIR}"
du -sh "${BUNDLE_DIR}"/{images,debs,bin,manifests,vm-manager} "${BUNDLE_DIR}" | sed 's/^/  /'
