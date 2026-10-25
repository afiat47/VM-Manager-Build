# Shared helpers for the m.sh build scripts. Source it after setting ROOT_DIR:
#
#   ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
#   source "${ROOT_DIR}/scripts/lib/common.sh"

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARNING: %s\033[0m\n' "$*" >&2; }
die() {
    printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2
    exit 1
}

# Load versions.env (every pinned version of the project) into the environment.
# CRs are stripped in case the file was saved with Windows line endings.
load_versions() {
    local f="${ROOT_DIR}/versions.env"
    [[ -f "${f}" ]] || die "missing ${f}"
    set -a
    # shellcheck disable=SC1090
    source <(tr -d '\r' <"${f}")
    set +a
}

KUBEVIRT_CRI="${KUBEVIRT_CRI:-docker}"
CRI="${CRI:-${KUBEVIRT_CRI}}"

# Run the container CLI. MSYS_NO_PATHCONV stops Git Bash on Windows from
# rewriting container-side paths such as /root into C:/Program Files/Git/root.
cri() { MSYS_NO_PATHCONV=1 "${CRI}" "$@"; }

require_cri() {
    command -v "${CRI}" >/dev/null 2>&1 || die "${CRI} is required (Docker Desktop on Windows, docker or podman on Linux)"
    cri info >/dev/null 2>&1 || die "cannot reach the ${CRI} daemon - is it running?"
}

# Host path in a form the container CLI understands (D:/... on Windows).
host_path() {
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$1"
    else
        printf '%s\n' "$1"
    fi
}

# Host-side git. safe.directory: the folder may have been copied from another
# machine/user. autocrlf=input: CRLF working files are read with LF, as stored.
hgit() { git -c safe.directory='*' -c core.autocrlf=input "$@"; }

# Fail unless the git checkout in $1 is based on tag $2 (the tag is an ancestor of
# HEAD), so a source tree on the wrong release can't slip into the ISO.
require_based_on() {
    local src="$1" tag="$2" name
    name="$(basename "${src}")"
    hgit -C "${src}" rev-parse --git-dir >/dev/null 2>&1 || die "${src} is not a git checkout"
    hgit -C "${src}" rev-parse -q --verify "refs/tags/${tag}" >/dev/null ||
        die "${name}: tag ${tag} (versions.env) not found in ${src}"
    hgit -C "${src}" merge-base --is-ancestor "${tag}" HEAD ||
        die "${name} is not based on ${tag} (versions.env); HEAD is $(hgit -C "${src}" describe --tags --always). Check out a branch made from ${tag}, e.g. git -C ${src} checkout -b vmm/${tag} ${tag}"
    # A newer release tag on top of the pinned one means the tree moved past it.
    local described
    described="$(hgit -C "${src}" describe --tags --abbrev=0 HEAD)"
    [[ "${described}" == "${tag}" ]] ||
        die "${name} is at ${described}, newer than ${tag} pinned in versions.env"
}

# Docker tags allow [A-Za-z0-9_.-] only.
sanitize_tag() { printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '_'; }

# --- Source snapshots ----------------------------------------------------------------------
# Builds never read the working folder directly: on Windows it has CRLF line endings and no
# symlinks. Instead they use a commit of HEAD + uncommitted changes to tracked files, exported
# with `git archive` (LF, real symlinks) and streamed into the build container.

# Prints the snapshot commit of $1 (HEAD itself when nothing is uncommitted).
# `git stash create` doesn't touch the working tree, index or stash list.
snapshot_commit() {
    local s
    s="$(hgit -C "$1" stash create 2>/dev/null || true)"
    if [[ -n "${s}" ]]; then
        printf '%s\n' "${s}"
    else
        hgit -C "$1" rev-parse HEAD
    fi
}

# Image tag for a snapshot: `git describe` of HEAD, plus -dirty for uncommitted changes.
snapshot_tag() {   # <src> <snapshot commit>
    local t
    t="$(hgit -C "$1" describe --tags --always HEAD)"
    if [[ "$2" != "$(hgit -C "$1" rev-parse HEAD)" ]]; then
        t="${t}-dirty"
    fi
    sanitize_tag "${t}"
}

# Warn about untracked files: they are not part of the snapshot.
warn_untracked() {
    local u
    u="$(hgit -C "$1" ls-files --others --exclude-standard | head -n 5)"
    if [[ -n "${u}" ]]; then
        warn "untracked files in $(basename "$1") are NOT included in the build (git add them to include):"
        sed 's/^/    /' <<<"${u}" >&2
    fi
}

# Write the snapshot as a tar to stdout.
archive_snapshot() {   # <src> <snapshot commit>
    hgit -C "$1" archive --format=tar "$2"
}

# Record "<name> <tag> <commit>" for versions.txt in the ISO.
record_build() {   # <output dir> <name> <tag> <commit>
    printf '%s %s %s\n' "$2" "$3" "$4" >"$1/build-info.txt"
}
