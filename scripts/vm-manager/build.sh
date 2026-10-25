#!/usr/bin/env bash
#
# Build the VM Manager image (React console + Spring Boot backend) from apps/VM-Manager,
# plus its deployment files and installer.
#
# Invoked through `./m.sh vm-manager`. The image is built with the project's own Dockerfile;
# the build context is a git snapshot of the sources (LF line endings), never the Windows
# working folder - installer/install.sh is served to joining servers and must not have CRLFs.
#
# Outputs:
#   docker/images/vm-manager/vm-manager.tar   the image (`docker save` format)
#   docker/images/vm-manager/images.txt       image references contained in the tarball
#   manifests/vm-manager/deploy/              deploy/vm-manager (kustomize) and deploy/cluster
#   manifests/vm-manager/installer/           install.sh
#
set -euo pipefail

ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
# shellcheck source=../lib/common.sh
source "${ROOT_DIR}/scripts/lib/common.sh"
load_versions

VMM_SRC="${VMM_SRC:-${ROOT_DIR}/apps/VM-Manager}"
VMM_IMAGES_DIR="${VMM_IMAGES_DIR:-${ROOT_DIR}/docker/images/vm-manager}"
VMM_MANIFESTS_DIR="${VMM_MANIFESTS_DIR:-${ROOT_DIR}/manifests/vm-manager}"
VMM_TAG="${VMM_TAG:-${VM_MANAGER_VERSION}}"

usage() {
    cat <<EOF
Usage: ./m.sh vm-manager [options]

Builds VM Manager from ${VMM_SRC#"${ROOT_DIR}/"} into
  ${VMM_IMAGES_DIR#"${ROOT_DIR}/"}/vm-manager.tar
  ${VMM_MANIFESTS_DIR#"${ROOT_DIR}/"}/{deploy,installer}

Options:
  -t, --tag TAG   Image tag [VMM_TAG] (default: VM_MANAGER_VERSION from versions.env, ${VM_MANAGER_VERSION})
  -h, --help      Show this help

Uncommitted changes to tracked files are included; untracked files are not (git add them).
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
    -t | --tag)
        VMM_TAG="${2:?--tag needs a value}"
        shift
        ;;
    -h | --help)
        usage
        exit 0
        ;;
    *) die "unknown option '$1' (see ./m.sh vm-manager --help)" ;;
    esac
    shift
done

require_cri
hgit -C "${VMM_SRC}" rev-parse --git-dir >/dev/null 2>&1 || die "${VMM_SRC} is not a git checkout"

log "Snapshotting VM Manager sources"
snapshot="$(snapshot_commit "${VMM_SRC}")"
VMM_TAG="$(sanitize_tag "${VMM_TAG}")"
warn_untracked "${VMM_SRC}"
# Same reference the cluster uses: kustomize turns "vm-manager" into vm-manager:<tag>.
image="vm-manager:${VMM_TAG}"
echo "Source: ${VMM_SRC} @ ${snapshot:0:12} ($(hgit -C "${VMM_SRC}" rev-parse --abbrev-ref HEAD))"
echo "Image:  ${image}"

log "Building ${image} (React + Spring Boot; the first build downloads npm and Maven packages)"
archive_snapshot "${VMM_SRC}" "${snapshot}" | cri build -t "${image}" -

log "Saving ${image}"
mkdir -p "${VMM_IMAGES_DIR}" "${VMM_MANIFESTS_DIR}"
rm -f "${VMM_IMAGES_DIR}"/*.tar
rm -rf "${VMM_MANIFESTS_DIR:?}"/*
cri save -o "$(host_path "${VMM_IMAGES_DIR}/vm-manager.tar")" "${image}"
cri rmi "${image}" >/dev/null 2>&1 || true
printf 'docker.io/library/%s\n' "${image}" >"${VMM_IMAGES_DIR}/images.txt"

# deploy/ and installer/ straight from the snapshot (LF line endings, no Windows CRLFs).
archive_snapshot "${VMM_SRC}" "${snapshot}" | tar -xf - -C "${VMM_MANIFESTS_DIR}" deploy installer
find "${VMM_MANIFESTS_DIR}" -name '*.bak-*' -delete
# The kustomization must deploy exactly the image built here.
kust="${VMM_MANIFESTS_DIR}/deploy/vm-manager/kustomization.yaml"
if grep -q '^[[:space:]]*newTag:' "${kust}"; then
    sed -i "s|^\([[:space:]]*newTag:\).*|\1 ${VMM_TAG}|" "${kust}"
else
    die "${kust} has no images/newTag entry for vm-manager"
fi

record_build "${VMM_IMAGES_DIR}" vm-manager "${VMM_TAG}" "${snapshot}"

log "VM Manager ${VMM_TAG} built"
ls -lh "${VMM_IMAGES_DIR}"/*.tar | awk '{print "  " $NF "  (" $5 ")"}'
echo "Manifests: ${VMM_MANIFESTS_DIR}"
