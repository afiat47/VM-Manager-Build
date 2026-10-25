#!/usr/bin/env bash
#
# Build KubeVirt container images and deployment manifests.
#
# Invoked through `./m.sh kubevirt`. The build runs entirely inside the
# upstream KubeVirt builder container (Bazel + toolchains), so the host only
# needs bash, git and docker (Docker Desktop on Windows, docker/podman on Linux).
#
# Outputs:
#   docker/images/kubevirt/<image>.tar   `docker save` compatible image tarballs
#   docker/images/kubevirt/images.txt    image references contained in the tarballs
#   manifests/kubevirt/*.yaml            kubevirt-operator.yaml, kubevirt-cr.yaml, ...
#
# Flow:
#   1. Snapshot the KubeVirt git tree (HEAD + uncommitted tracked changes) into
#      a temporary ref, so the container gets a clean LF checkout regardless of
#      the host's core.autocrlf / symlink settings.
#   2. Inside the builder container, build each image with Bazel straight into
#      a tarball (rules_img image_load, "tarball" output group) - no registry
#      and no docker daemon involved.
#   3. Generate the deployment manifests for the chosen image prefix/tag.
#   4. Copy tarballs and manifests out of the build volume.
#
set -euo pipefail

ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# Pinned versions (KUBEVIRT_VERSION, ...) and shared helpers.
# shellcheck source=../lib/common.sh
source "${ROOT_DIR}/scripts/lib/common.sh"
load_versions

# ---------------------------------------------------------------------------
# Configuration (environment variables, overridable by command-line flags)
# ---------------------------------------------------------------------------
KUBEVIRT_SRC="${KUBEVIRT_SRC:-${ROOT_DIR}/apps/kubevirt}"
KUBEVIRT_IMAGES_DIR="${KUBEVIRT_IMAGES_DIR:-${ROOT_DIR}/docker/images/kubevirt}"
KUBEVIRT_MANIFESTS_DIR="${KUBEVIRT_MANIFESTS_DIR:-${ROOT_DIR}/manifests/kubevirt}"
# Image name prefix (registry/org) baked into the tarballs and the manifests.
KUBEVIRT_IMAGE_PREFIX="${KUBEVIRT_IMAGE_PREFIX:-kubevirt}"
# Image tag; defaults to `git describe` of the KubeVirt sources.
KUBEVIRT_TAG="${KUBEVIRT_TAG:-}"
# Images needed to deploy KubeVirt. Any name with a //:push-<name> target in
# apps/kubevirt/BUILD.bazel can be added (sidecar-shim, pr-helper, ...).
KUBEVIRT_IMAGES="${KUBEVIRT_IMAGES:-virt-operator virt-api virt-controller virt-handler virt-launcher virt-exportserver virt-exportproxy virt-synchronization-controller virt-template-apiserver virt-template-controller}"
BUILD_ARCH="${BUILD_ARCH:-x86_64}"
KUBEVIRT_CRI="${KUBEVIRT_CRI:-docker}"
CRI="${KUBEVIRT_CRI}"
# Run gazelle on pkg/ tools/ tests/ cmd/ before building (like upstream
# `make bazel-build`), so new Go files and imports end up in BUILD.bazel.
KUBEVIRT_GAZELLE="${KUBEVIRT_GAZELLE:-true}"
# Run the full upstream code generation (`make generate`): deepcopy, openapi,
# CRDs, manifests/generated, ... Needed after API type changes. Slow.
KUBEVIRT_GENERATE="${KUBEVIRT_GENERATE:-false}"
# Copy files changed by gazelle/generate back into KUBEVIRT_SRC.
KUBEVIRT_SYNC_BACK="${KUBEVIRT_SYNC_BACK:-true}"

BUILD_VOLUME="vm-manager-kubevirt-build"
SNAPSHOT_REF="refs/m-sh/kubevirt-build"
CONTAINER_WS="/root/go/src/kubevirt.io/kubevirt"
CONTAINER_EXPORT="${CONTAINER_WS}/_out/vm-manager"

usage() {
    cat <<EOF
Usage: ./m.sh kubevirt [options]
       ./m.sh kubevirt clean

Builds the KubeVirt images from ${KUBEVIRT_SRC#"${ROOT_DIR}/"} into
  ${KUBEVIRT_IMAGES_DIR#"${ROOT_DIR}/"}/<image>.tar
  ${KUBEVIRT_MANIFESTS_DIR#"${ROOT_DIR}/"}/*.yaml

Options (environment variable in brackets):
  -t, --tag TAG        Image tag                 [KUBEVIRT_TAG]          (default: git describe)
  -p, --prefix PREFIX  Image registry/prefix     [KUBEVIRT_IMAGE_PREFIX] (default: kubevirt)
  -i, --images "A B"   Images to build           [KUBEVIRT_IMAGES]       (default: core deploy set)
  -a, --arch ARCH      x86_64 | aarch64 | s390x  [BUILD_ARCH]            (default: x86_64)
      --generate       Run full code generation  [KUBEVIRT_GENERATE=true]
                       (needed after changing API types in staging/src/kubevirt.io/api)
      --no-gazelle     Skip BUILD.bazel update   [KUBEVIRT_GAZELLE=false]
      --no-sync-back   Don't copy generated/BUILD.bazel changes back into the sources
                                                 [KUBEVIRT_SYNC_BACK=false]
  -h, --help           Show this help

Other variables: KUBEVIRT_SRC, KUBEVIRT_IMAGES_DIR, KUBEVIRT_MANIFESTS_DIR,
KUBEVIRT_CRI (docker|podman), KUBEVIRT_BUILDER_IMAGE.

Changing KubeVirt: edit files, 'git add' brand-new files (no commit needed), then
run ./m.sh kubevirt. BUILD.bazel files are updated automatically (gazelle) and
copied back into ${KUBEVIRT_SRC#"${ROOT_DIR}/"} so you can commit them with your change.

'clean' removes the build cache volume (the next build starts from scratch).

Examples:
  ./m.sh kubevirt
  ./m.sh kubevirt --prefix registry.example.com/kubevirt --tag v1.9.0-dev
EOF
}


# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
ACTION=build
while [[ $# -gt 0 ]]; do
    case "$1" in
    clean) ACTION=clean ;;
    -t | --tag)
        KUBEVIRT_TAG="${2:?--tag needs a value}"
        shift
        ;;
    -p | --prefix)
        KUBEVIRT_IMAGE_PREFIX="${2:?--prefix needs a value}"
        shift
        ;;
    -i | --images)
        KUBEVIRT_IMAGES="${2:?--images needs a value}"
        shift
        ;;
    -a | --arch)
        BUILD_ARCH="${2:?--arch needs a value}"
        shift
        ;;
    --generate) KUBEVIRT_GENERATE=true ;;
    --no-gazelle) KUBEVIRT_GAZELLE=false ;;
    --no-sync-back) KUBEVIRT_SYNC_BACK=false ;;
    -h | --help)
        usage
        exit 0
        ;;
    *) die "unknown option '$1' (see ./m.sh kubevirt --help)" ;;
    esac
    shift
done

KUBEVIRT_IMAGE_PREFIX="${KUBEVIRT_IMAGE_PREFIX%/}"

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
command -v "${KUBEVIRT_CRI}" >/dev/null 2>&1 || die "${KUBEVIRT_CRI} is required (install Docker Desktop on Windows, docker or podman on Linux)"
cri info >/dev/null 2>&1 || die "cannot reach the ${KUBEVIRT_CRI} daemon - is it running and is your user allowed to use it?"

if [[ "${ACTION}" == clean ]]; then
    log "Removing KubeVirt build cache volume"
    cri volume rm -f "${BUILD_VOLUME}" >/dev/null 2>&1 || true
    echo "Done. ${KUBEVIRT_IMAGES_DIR} and ${KUBEVIRT_MANIFESTS_DIR} were left untouched."
    exit 0
fi

command -v git >/dev/null 2>&1 || die "git is required"
[[ -f "${KUBEVIRT_SRC}/hack/dockerized" ]] || die "KubeVirt sources not found at ${KUBEVIRT_SRC}"

case "${BUILD_ARCH}" in
x86_64 | amd64) BUILD_ARCH=x86_64 ;;
aarch64 | arm64) BUILD_ARCH=aarch64 ;;
s390x) ;;
*) die "unsupported arch '${BUILD_ARCH}' (use x86_64, aarch64 or s390x; one at a time)" ;;
esac

mem_bytes="$(cri info --format '{{.MemTotal}}' 2>/dev/null || echo 0)"
if [[ "${mem_bytes}" =~ ^[0-9]+$ ]] && ((mem_bytes > 0 && mem_bytes < 8 * 1024 * 1024 * 1024)); then
    warn "the container engine has only $((mem_bytes / 1024 / 1024)) MiB of memory; the Bazel build needs 8 GiB or more"
fi

# Use the same builder image as upstream hack/dockerized.
if [[ -z "${KUBEVIRT_BUILDER_IMAGE:-}" ]]; then
    builder_version="$(sed -n 's/^kubevirt_builder_version="\{0,1\}\([^"]*\)"\{0,1\}.*/\1/p' "${KUBEVIRT_SRC}/hack/dockerized" | tr -d '\r' | head -n1)"
    [[ -n "${builder_version}" ]] || die "could not determine builder version from hack/dockerized; set KUBEVIRT_BUILDER_IMAGE"
    if [[ "${BUILD_ARCH}" == "$(uname -m)" ]]; then
        KUBEVIRT_BUILDER_IMAGE="quay.io/kubevirt/builder:${builder_version}"
    else
        KUBEVIRT_BUILDER_IMAGE="quay.io/kubevirt/builder-cross:${builder_version}"
    fi
fi

# ---------------------------------------------------------------------------
# 1. Snapshot the sources
# ---------------------------------------------------------------------------
log "Snapshotting KubeVirt sources"
cd "${KUBEVIRT_SRC}"
hgit rev-parse --git-dir >/dev/null 2>&1 || die "${KUBEVIRT_SRC} is not a git checkout (copy it together with its .git directory)"
# The tree must be on the release pinned in versions.env (your changes on top are fine).
if [[ "${KUBEVIRT_ALLOW_ANY_VERSION:-false}" != true ]]; then
    require_based_on "${KUBEVIRT_SRC}" "${KUBEVIRT_VERSION}"
fi

# `git stash create` makes a commit of HEAD + uncommitted tracked changes
# without touching the working tree, index or stash list.
head="$(hgit rev-parse HEAD)"
snapshot="$(hgit stash create 2>/dev/null || true)"
if [[ -n "${snapshot}" ]]; then
    echo "Including uncommitted changes to tracked files."
else
    snapshot="${head}"
fi
untracked="$(hgit ls-files --others --exclude-standard | head -n 5)"
if [[ -n "${untracked}" ]]; then
    warn "untracked files are NOT included in the build (git add them to include):"
    sed 's/^/    /' <<<"${untracked}" >&2
fi

hgit update-ref "${SNAPSHOT_REF}" "${snapshot}"
cleanup_ref() { hgit -C "${KUBEVIRT_SRC}" update-ref -d "${SNAPSHOT_REF}" >/dev/null 2>&1 || true; }
trap cleanup_ref EXIT

if [[ -z "${KUBEVIRT_TAG}" ]]; then
    KUBEVIRT_TAG="$(hgit describe --tags --always "${head}")"
    if [[ "${snapshot}" != "${head}" ]]; then
        KUBEVIRT_TAG="${KUBEVIRT_TAG}-dirty"
    fi
fi
# Docker tags allow [A-Za-z0-9_.-] only.
KUBEVIRT_TAG="$(printf '%s' "${KUBEVIRT_TAG}" | tr -c 'A-Za-z0-9_.-' '_')"
GIT_DIR_HOST="$(host_path "$(hgit rev-parse --absolute-git-dir)")"
cd "${ROOT_DIR}"

echo "Source:   ${KUBEVIRT_SRC} @ ${snapshot:0:12}"
echo "Images:   ${KUBEVIRT_IMAGE_PREFIX}/{${KUBEVIRT_IMAGES// /,}}:${KUBEVIRT_TAG}"
echo "Arch:     ${BUILD_ARCH}"
echo "Builder:  ${KUBEVIRT_BUILDER_IMAGE}"
echo "Codegen:  gazelle=${KUBEVIRT_GAZELLE} generate=${KUBEVIRT_GENERATE} sync-back=${KUBEVIRT_SYNC_BACK}"

# ---------------------------------------------------------------------------
# 2./3. Bazel build + manifests inside the builder container
# ---------------------------------------------------------------------------
log "Pulling builder image"
cri pull "${KUBEVIRT_BUILDER_IMAGE}"

proxy_env=()
for v in HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy; do
    if [[ -n "${!v:-}" ]]; then
        proxy_env+=(-e "${v}=${!v}")
    fi
done

log "Building images with Bazel (the first run takes a long time)"
# The script is fed on stdin; strip CRs in case this file was checked out with CRLF.
tr -d '\r' <<'INNER' | cri run --rm -i \
    --ulimit nofile=10000:10000 \
    --security-opt label=disable \
    -v "${BUILD_VOLUME}:/root" \
    -v "${GIT_DIR_HOST}:/src.git:ro" \
    -e "WS=${CONTAINER_WS}" \
    -e "EXPORT=${CONTAINER_EXPORT}" \
    -e "SNAPSHOT_REF=${SNAPSHOT_REF}" \
    -e "BUILD_ARCH=${BUILD_ARCH}" \
    -e "DOCKER_TAG=${KUBEVIRT_TAG}" \
    -e "FINAL_PREFIX=${KUBEVIRT_IMAGE_PREFIX}" \
    -e "IMAGES=${KUBEVIRT_IMAGES}" \
    -e "RUN_GAZELLE=${KUBEVIRT_GAZELLE}" \
    -e "RUN_GENERATE=${KUBEVIRT_GENERATE}" \
    ${proxy_env[@]+"${proxy_env[@]}"} \
    -w /root \
    --entrypoint /entrypoint.sh \
    "${KUBEVIRT_BUILDER_IMAGE}" "bash -s"
# No `set -u`: the upstream hack/ scripts rely on unset variables.
set -eo pipefail
git config --global --add safe.directory '*'

mkdir -p "${WS}"
cd "${WS}"
[ -d .git ] || git init -q .
echo "Syncing sources into the build volume"
git fetch -q --force --tags /src.git "+${SNAPSHOT_REF}:${SNAPSHOT_REF}"
git checkout -q -f --detach "${SNAPSHOT_REF}"
# Keep ignored paths (bazel caches, .bazeldnf sandbox, _out) between runs.
git clean -q -fd

# rules_img (KubeVirt >= 1.10) pulls base images "shallow" (metadata only, enough
# for registry pushes); self-contained tarballs need the real layers, so download
# them. rules_oci (KubeVirt 1.9) has no `pull(` rules and always downloads layers.
# Patched before the first bazel call so the repositories are stable across runs.
sed -i '/^pull(/a\    layer_handling = "eager",' WORKSPACE

rm -rf "${EXPORT}"
mkdir -p "${EXPORT}/images" "${EXPORT}/codegen/source"

source hack/common.sh
source hack/bootstrap.sh
source hack/config.sh

# Code generation, same steps as upstream `make generate` / `make bazel-build`.
# DOCKER_TAG/DOCKER_PREFIX are unset so generated examples keep upstream defaults.
if [ "${RUN_GENERATE}" = "true" ]; then
    echo "Running code generation (hack/generate.sh, hack/bazel-generate.sh)"
    (
        unset DOCKER_TAG DOCKER_PREFIX
        ./hack/build-ginkgo.sh
        ./hack/generate.sh
        ./hack/bazel-generate.sh
        ./hack/bazel-fmt.sh
    )
elif [ "${RUN_GAZELLE}" = "true" ]; then
    echo "Updating BUILD.bazel files (gazelle)"
    bazel run --config="${HOST_ARCHITECTURE}" ${BAZEL_CS_CONFIG} //:gazelle -- pkg/ tools/ tests/ cmd/
fi

# Record what code generation changed relative to the snapshot, so the host
# can copy it back into its source tree.
# (WORKSPACE is excluded: it only carries the layer_handling patch above.)
git status --porcelain=v1 --untracked-files=all --no-renames | { grep -v -x '.. WORKSPACE' || true; } >"${EXPORT}/codegen/status.txt"
awk '$1 != "D" { print substr($0, 4) }' "${EXPORT}/codegen/status.txt" |
    xargs -r -d '\n' cp -a --parents -t "${EXPORT}/codegen/source/"
awk '$1 == "D" { print substr($0, 4) }' "${EXPORT}/codegen/status.txt" >"${EXPORT}/codegen/deleted.txt"
if [ -s "${EXPORT}/codegen/status.txt" ]; then
    echo "Code generation changed $(wc -l <"${EXPORT}/codegen/status.txt") file(s)"
fi

ARCHITECTURE="$(format_archname "${BUILD_ARCH}")"

# Add a load target per image to the root package (where the upstream
# //:push-<image> targets live, so every image target is visible from there).
# The checkout is reset on every run, so this never leaks into the sources.
# KubeVirt >= 1.10 builds images with rules_img, older releases (1.9) with rules_oci.
if grep -q '@rules_img//img:push.bzl' BUILD.bazel; then
    image_rules=rules_img
else
    image_rules=rules_oci
fi
echo "Image rules: ${image_rules}"
# virt-template (deployed by virt-operator since KubeVirt 1.9) has its own version, set in
# hack/virt-template/default.sh; all other images use the KubeVirt tag.
vt_version=""
if [ -f hack/virt-template/default.sh ]; then
    vt_version="$(unset VIRT_TEMPLATE_VERSION; . hack/virt-template/default.sh; echo "${virt_template_version}")"
fi
tag_for() {
    case "$1" in
    virt-template-*)
        [ -n "${vt_version}" ] || { echo "ERROR: $1 requested, but this KubeVirt has no hack/virt-template/default.sh" >&2; exit 1; }
        echo "${vt_version}"
        ;;
    *) echo "${DOCKER_TAG}" ;;
    esac
}
case " ${IMAGES} " in
*" virt-template-"*)
    if [ -z "${vt_version}" ]; then
        echo "ERROR: virt-template images requested, but this KubeVirt has no hack/virt-template/default.sh" >&2
        exit 1
    fi
    ;;
esac

targets=()
for img in ${IMAGES}; do
    label="$(awk -v want="push-${img}" '
        /(image_push|oci_push)\(/ { p = 1; n = "" }
        p && /^[[:space:]]*name[[:space:]]*=/  { gsub(/[",]/, "", $3); n = $3 }
        p && /^[[:space:]]*image[[:space:]]*=/ { gsub(/[",]/, "", $3); if (n == want) print $3; p = 0 }
    ' BUILD.bazel)"
    if [ -z "${label}" ]; then
        echo "ERROR: unknown image '${img}' (no //:push-${img} target in BUILD.bazel)" >&2
        exit 1
    fi
    if [ "${image_rules}" = rules_img ]; then
        cat >>BUILD.bazel <<EOT

image_load(
    name = "vmm-load-${img}",
    image = "${label}",
    tag = "${FINAL_PREFIX}/${img}:$(tag_for "${img}")",
    strategy = "eager",
)
EOT
    else
        cat >>BUILD.bazel <<EOT

oci_load(
    name = "vmm-load-${img}",
    image = "${label}",
    repo_tags = ["${FINAL_PREFIX}/${img}:$(tag_for "${img}")"],
)
EOT
    fi
    targets+=("//:vmm-load-${img}")
done
if [ "${image_rules}" = rules_img ]; then
    sed -i '1i load("@rules_img//img:load.bzl", "image_load")' BUILD.bazel
else
    sed -i '1i load("@rules_oci//oci:defs.bzl", "oci_load")' BUILD.bazel
fi

bazel build --config="${ARCHITECTURE}" ${BAZEL_CS_CONFIG} --output_groups=+tarball "${targets[@]}"

for img in ${IMAGES}; do
    tarball="$(bazel cquery --config="${ARCHITECTURE}" ${BAZEL_CS_CONFIG} --output=files --output_groups=tarball "//:vmm-load-${img}" 2>/dev/null | grep '\.tar$' | head -n1 || true)"
    if [ -z "${tarball}" ]; then
        tarball="$(find -L bazel-bin/ -maxdepth 2 -path "*vmm-load-${img}*" -name '*.tar' | head -n1)"
    fi
    if [ -z "${tarball}" ] || [ ! -f "${tarball}" ]; then
        echo "ERROR: no tarball produced for ${img}" >&2
        exit 1
    fi
    out="${EXPORT}/images/${img}.tar"
    cp -fL "${tarball}" "${out}"
    chmod 0644 "${out}"
    ref="${FINAL_PREFIX}/${img}:$(tag_for "${img}")"

    # rules_img only names the image in manifest.json (classic `docker load`).
    # containerd (`ctr images import`, Docker's containerd image store) reads
    # index.json instead, so add the standard name annotations there too.
    if tar -tf "${out}" index.json >/dev/null 2>&1; then
        first="${ref%%/*}"
        case "${first}" in
        *.* | *:* | localhost) full="${ref}" ;;
        *) full="docker.io/${ref}" ;;
        esac
        # Repack instead of `tar --delete`, which corrupts large trailing entries.
        work="$(mktemp -d)"
        mkdir "${work}/root"
        tar -tf "${out}" >"${work}/order"
        tar -xf "${out}" -C "${work}/root"
        jq --arg name "${full}" --arg tag "$(tag_for "${img}")" \
            '.manifests |= map(.annotations = ((.annotations // {}) + {"io.containerd.image.name": $name, "org.opencontainers.image.ref.name": $tag}))' \
            "${work}/root/index.json" >"${work}/index.json"
        mv -f "${work}/index.json" "${work}/root/index.json"
        tar -cf "${out}" -C "${work}/root" --no-recursion --owner=0 --group=0 --numeric-owner --mtime=@0 -T "${work}/order"
        rm -rf "${work}"
    fi
    echo "${ref}" >>"${EXPORT}/images/images.txt"
    echo "  ${ref} -> ${img}.tar"
done

echo "Generating deployment manifests"
DOCKER_PREFIX="${FINAL_PREFIX}" ./hack/build-manifests.sh
mkdir -p "${EXPORT}/manifests"
cp -rf _out/manifests/release/. "${EXPORT}/manifests/"
# virt-operator deploys virt-template with this version (checked by ./m.sh bundle).
if [ -n "${vt_version}" ]; then echo "${vt_version}" >"${EXPORT}/manifests/virt-template-version"; fi
INNER

# ---------------------------------------------------------------------------
# 4. Copy outputs to the host
# ---------------------------------------------------------------------------
log "Copying images to ${KUBEVIRT_IMAGES_DIR}"
mkdir -p "${KUBEVIRT_IMAGES_DIR}" "${KUBEVIRT_MANIFESTS_DIR}"
rm -f "${KUBEVIRT_IMAGES_DIR}"/*.tar "${KUBEVIRT_IMAGES_DIR}/images.txt"
rm -rf "${KUBEVIRT_MANIFESTS_DIR:?}"/*

copy_cid="$(cri create -v "${BUILD_VOLUME}:/root" "${KUBEVIRT_BUILDER_IMAGE}" true)"
copy_out() { cri cp "${copy_cid}:${CONTAINER_EXPORT}/$1/." "$(host_path "$2")"; }
status_dir="$(mktemp -d)"
cleanup() {
    cri rm -f "${copy_cid}" >/dev/null 2>&1 || true
    rm -rf "${status_dir}"
    cleanup_ref
}
trap cleanup EXIT

copy_out images "${KUBEVIRT_IMAGES_DIR}" &&
    copy_out manifests "${KUBEVIRT_MANIFESTS_DIR}" &&
    copy_out codegen "${status_dir}" ||
    die "could not copy the build outputs out of the build volume"

# Copy BUILD.bazel / generated-code changes back into the host sources.
changes="$(grep -v '^$' "${status_dir}/status.txt" 2>/dev/null || true)"
if [[ -n "${changes}" ]]; then
    if [[ "${KUBEVIRT_SYNC_BACK}" == true ]]; then
        log "Copying code generation changes back into ${KUBEVIRT_SRC}"
        cp -a "${status_dir}/source/." "${KUBEVIRT_SRC}/"
        while IFS= read -r f; do
            [[ -n "${f}" ]] && rm -f -- "${KUBEVIRT_SRC}/${f}"
        done <"${status_dir}/deleted.txt"
        sed 's/^/  /' <<<"${changes}"
        echo "Review them with 'git status' in ${KUBEVIRT_SRC} and commit them together with your change."
    else
        warn "code generation changed these files in the build only (--no-sync-back):"
        sed 's/^/    /' <<<"${changes}" >&2
    fi
fi

# images.txt (written in the build, with each image's own tag) came with the images.
record_build "${KUBEVIRT_IMAGES_DIR}" kubevirt "${KUBEVIRT_TAG}" "${snapshot}"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
log "KubeVirt ${KUBEVIRT_TAG} built"
echo "Images:    ${KUBEVIRT_IMAGES_DIR}"
(cd "${KUBEVIRT_IMAGES_DIR}" && ls -lh -- *.tar | awk '{print "  " $NF "  (" $5 ")"}')
echo "Manifests: ${KUBEVIRT_MANIFESTS_DIR}"
echo
echo "To deploy: load each tarball where the cluster can use it, e.g."
echo "  docker load -i <image>.tar                  (then docker push to your registry)"
echo "  ctr -n k8s.io images import <image>.tar     (directly on a containerd node)"
echo "then:"
echo "  kubectl apply -f kubevirt-operator.yaml"
echo "  kubectl apply -f kubevirt-cr.yaml"
