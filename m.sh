#!/usr/bin/env bash
#
# m.sh - build entry point for VM-Manager-Build.
#
# Usage:
#   ./m.sh <target> [args...]
#
# Targets:
#   kubevirt         Build KubeVirt images + manifests from apps/kubevirt
#   rook             Build the Rook operator image + manifests from apps/rook
#   vm-manager       Build the VM Manager image + deploy files from apps/VM-Manager
#   deps             Download everything else the ISO needs (pinned in versions.env)
#   bundle           Collect all build outputs into bundle/ (checks nothing is missing)
#   iso              Build the installer ISO from Ubuntu Server + bundle/
#   all              kubevirt, rook, vm-manager, deps, bundle, iso
#   test-iso         Install an --unattended ISO in a QEMU VM without internet and check it
#   help             Show this help
#
# Most targets accept --help, e.g. ./m.sh kubevirt --help.
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export ROOT_DIR

usage() {
    sed -n '3,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

run() { bash "${ROOT_DIR}/scripts/$1" "${@:2}"; }

target="${1:-help}"
[[ $# -gt 0 ]] && shift

case "${target}" in
kubevirt | kubvirt) run kubevirt/build.sh "$@" ;;
rook) run rook/build.sh "$@" ;;
vm-manager | vmm) run vm-manager/build.sh "$@" ;;
deps) run deps/download.sh "$@" ;;
bundle) run bundle/bundle.sh "$@" ;;
iso) run iso/build.sh "$@" ;;
test-iso) run test/iso-test.sh "$@" ;;
all)
    run kubevirt/build.sh
    run rook/build.sh
    run vm-manager/build.sh
    run deps/download.sh
    run bundle/bundle.sh
    run iso/build.sh "$@"
    ;;
help | -h | --help)
    usage
    ;;
*)
    echo "m.sh: unknown target '${target}'" >&2
    echo >&2
    usage >&2
    exit 1
    ;;
esac
