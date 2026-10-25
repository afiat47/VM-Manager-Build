#!/usr/bin/env bash
#
# Build the Rook operator image (rook/ceph) from apps/rook, plus Rook's install manifests.
#
# Invoked through `./m.sh rook`. Uses Rook's own Makefile targets (go.build, then the image
# build) inside a pinned Go container that talks to the host's Docker for `docker build`.
#
# Outputs:
#   docker/images/rook/rook-ceph.tar     the operator image (`docker save` format)
#   docker/images/rook/images.txt        image references contained in the tarballs
#   manifests/rook/*.yaml                crds, common, csi-operator, operator (using the built image)
#   manifests/rook/upstream-images.txt   other images Rook needs (Ceph, CSI); bundled by ./m.sh deps
#
set -euo pipefail

ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
# shellcheck source=../lib/common.sh
source "${ROOT_DIR}/scripts/lib/common.sh"
load_versions

ROOK_SRC="${ROOK_SRC:-${ROOT_DIR}/apps/rook}"
ROOK_IMAGES_DIR="${ROOK_IMAGES_DIR:-${ROOT_DIR}/docker/images/rook}"
ROOK_MANIFESTS_DIR="${ROOK_MANIFESTS_DIR:-${ROOT_DIR}/manifests/rook}"
# Same name as the upstream image, so a clean build is a drop-in for docker.io/rook/ceph:v1.20.8.
ROOK_IMAGE_PREFIX="${ROOK_IMAGE_PREFIX:-docker.io/rook}"
ROOK_TAG="${ROOK_TAG:-}"

BUILD_VOLUME="vm-manager-rook-build"
GO_MOD_VOLUME="vm-manager-go-mod-cache"
GO_BUILD_VOLUME="vm-manager-go-build-cache"
# Manifests installed by VM Manager's installer, from deploy/examples.
MANIFESTS="crds.yaml common.yaml csi-operator.yaml operator.yaml"

usage() {
    cat <<EOF
Usage: ./m.sh rook [options]
       ./m.sh rook clean

Builds the Rook operator image from ${ROOK_SRC#"${ROOT_DIR}/"} (must be based on ${ROOK_VERSION}) into
  ${ROOK_IMAGES_DIR#"${ROOT_DIR}/"}/rook-ceph.tar
  ${ROOK_MANIFESTS_DIR#"${ROOT_DIR}/"}/*.yaml

Options:
  -t, --tag TAG   Image tag [ROOK_TAG] (default: git describe, e.g. ${ROOK_VERSION})
  -h, --help      Show this help

Uncommitted changes to tracked files are included; untracked files are not (git add them).
'clean' removes the Rook and Go build caches.
EOF
}

ACTION=build
while [[ $# -gt 0 ]]; do
    case "$1" in
    clean) ACTION=clean ;;
    -t | --tag)
        ROOK_TAG="${2:?--tag needs a value}"
        shift
        ;;
    -h | --help)
        usage
        exit 0
        ;;
    *) die "unknown option '$1' (see ./m.sh rook --help)" ;;
    esac
    shift
done

require_cri

if [[ "${ACTION}" == clean ]]; then
    log "Removing Rook build caches"
    cri volume rm -f "${BUILD_VOLUME}" "${GO_MOD_VOLUME}" "${GO_BUILD_VOLUME}" >/dev/null 2>&1 || true
    echo "Done."
    exit 0
fi

# ---------------------------------------------------------------------------
# Source snapshot
# ---------------------------------------------------------------------------
log "Snapshotting Rook sources"
if [[ "${ROOK_ALLOW_ANY_VERSION:-false}" != true ]]; then
    require_based_on "${ROOK_SRC}" "${ROOK_VERSION}"
fi
snapshot="$(snapshot_commit "${ROOK_SRC}")"
[[ -n "${ROOK_TAG}" ]] || ROOK_TAG="$(snapshot_tag "${ROOK_SRC}" "${snapshot}")"
ROOK_TAG="$(sanitize_tag "${ROOK_TAG}")"
warn_untracked "${ROOK_SRC}"
image="${ROOK_IMAGE_PREFIX%/}/ceph:${ROOK_TAG}"
builder="vm-manager/rook-builder:$(printf '%s %s' "${ROOK_GO_IMAGE}" "${DOCKER_CLI_IMAGE}" | sha256sum | cut -c1-12)"

echo "Source:  ${ROOK_SRC} @ ${snapshot:0:12}"
echo "Image:   ${image}"
echo "Builder: ${ROOK_GO_IMAGE} + docker CLI"

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------
if ! cri image inspect "${builder}" >/dev/null 2>&1; then
    log "Preparing the Rook builder image"
    printf 'FROM %s\nCOPY --from=%s /usr/local/bin/docker /usr/local/bin/docker\n' \
        "${ROOK_GO_IMAGE}" "${DOCKER_CLI_IMAGE}" | cri build -q -t "${builder}" - >/dev/null
fi

log "Building rook and the rook/ceph image"
# The snapshot is streamed in as a tar; Rook's Makefile gets VERSION explicitly because
# the exported tree has no .git. The inner `docker build` runs on the host's daemon.
archive_snapshot "${ROOK_SRC}" "${snapshot}" | cri run --rm -i \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "${BUILD_VOLUME}:/work" \
    -v "${GO_MOD_VOLUME}:/go/pkg/mod" \
    -v "${GO_BUILD_VOLUME}:/root/.cache/go-build" \
    -e "VERSION=${ROOK_TAG}" \
    -e "IMAGE=${image}" \
    --entrypoint bash "${builder}" -c '
set -euo pipefail
rm -rf /work/rook
mkdir -p /work/rook
cd /work/rook
tar -xf -
git config --global --add safe.directory "*"
make go.build PLATFORM=linux_amd64 VERSION="${VERSION}"
make -C images PLATFORM=linux_amd64 VERSION="${VERSION}" BUILD_REGISTRY=vmm-rook-build
docker tag vmm-rook-build/ceph-amd64 "${IMAGE}"
docker rmi vmm-rook-build/ceph-amd64 >/dev/null
'

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------
log "Saving ${image}"
mkdir -p "${ROOK_IMAGES_DIR}" "${ROOK_MANIFESTS_DIR}"
rm -f "${ROOK_IMAGES_DIR}"/*.tar
rm -rf "${ROOK_MANIFESTS_DIR:?}"/*
cri save -o "$(host_path "${ROOK_IMAGES_DIR}/rook-ceph.tar")" "${image}"
cri rmi "${image}" >/dev/null 2>&1 || true
printf '%s\n' "${image}" >"${ROOK_IMAGES_DIR}/images.txt"

# Manifests come from the snapshot too (git show prints blobs as stored, with LF).
upstream_image="$(hgit -C "${ROOK_SRC}" show "${snapshot}:deploy/examples/operator.yaml" | awk '/^[[:space:]]*image:/ {print $2; exit}')"
for f in ${MANIFESTS}; do
    hgit -C "${ROOK_SRC}" show "${snapshot}:deploy/examples/${f}" |
        sed "s|image: ${upstream_image}\$|image: ${image}|" >"${ROOK_MANIFESTS_DIR}/${f}"
done
grep -q "image: ${image}\$" "${ROOK_MANIFESTS_DIR}/operator.yaml" ||
    die "operator.yaml does not reference ${image} (upstream image: ${upstream_image})"

# Everything else Rook deploys (Ceph, CSI drivers and sidecars), as listed by upstream for
# offline installs; ./m.sh deps downloads these.
hgit -C "${ROOK_SRC}" show "${snapshot}:deploy/examples/images.txt" |
    grep -v -x "${upstream_image}" | grep -v '^[[:space:]]*$' >"${ROOK_MANIFESTS_DIR}/upstream-images.txt"

record_build "${ROOK_IMAGES_DIR}" rook "${ROOK_TAG}" "${snapshot}"

log "Rook ${ROOK_TAG} built"
ls -lh "${ROOK_IMAGES_DIR}"/*.tar | awk '{print "  " $NF "  (" $5 ")"}'
echo "Manifests: ${ROOK_MANIFESTS_DIR}"
sed 's/^/  needs: /' "${ROOK_MANIFESTS_DIR}/upstream-images.txt"
