#!/usr/bin/env bash
#
# Build QEMU inside the qemu_builder image (installed as
# /usr/local/bin/qemu-build.sh).
#
# Environment:
#   JOBS    default for -j/--jobs
#   HOST_UID/HOST_GID
#           owner for the mounted source tree and the build directory. When
#           the container starts as root (the default), the ownership of both
#           is fixed to this user -- by default the owner of the source tree --
#           and the build is re-executed as that user, so no root-owned files
#           are left behind in the host tree.
#   BUILD_AS_ROOT
#           1 to skip the ownership fix and build as root

set -euo pipefail

src=/build/qemu
build_dir=/build/qemu/build
jobs=${JOBS:-}
configure_args=()

# Arguments as given by the caller: the loop below rewrites "$@", but a
# re-execution as the host user (see the ownership handling further down) has
# to pass the original command line on.
orig_args=("$@")

usage() {
    cat <<'EOF'
Usage: qemu-build.sh [options] [-- <configure args...>]

Configure and build QEMU out-of-tree inside the qemu_builder image.

Options:
  -s, --src DIR        QEMU source tree (default: /build/qemu).
  -b, --build-dir DIR  directory to configure and build in; created if
                       missing (default: /build/qemu/build).
  -j, --jobs N         parallel jobs. Default: $JOBS; if that is unset too,
                       ninja uses its own default and make uses `nproc`.
  --                   everything after it is passed to <src>/configure.
  -h, --help           show this help and exit.

Examples:
  # build in the default place (source mounted at /build/qemu)
  docker run --rm -v ~/src/qemu:/build/qemu \
      -e HOST_UID=$(id -u) -e HOST_GID=$(id -g) qemu_builder:latest \
      qemu-build.sh -j 8 -- --target-list=x86_64-softmmu

  # build somewhere else
  qemu-build.sh -b /build/out -- --enable-debug

Mount the source tree read-write: the build writes into it (and into the
build directory, which defaults to <src>/build) as the host user, so the
resulting files keep their normal ownership.
EOF
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

log() { printf '\n>>> %s\n' "$*"; }

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        -s|--src)
            [ $# -ge 2 ] || die "$1 requires an argument"
            src=$2
            shift 2
            ;;
        -b|--build-dir)
            [ $# -ge 2 ] || die "$1 requires an argument"
            build_dir=$2
            shift 2
            ;;
        -j|--jobs)
            [ $# -ge 2 ] || die "$1 requires an argument"
            jobs=$2
            shift 2
            ;;
        --)
            shift
            configure_args=("$@")
            break
            ;;
        -*)
            die "unknown option: $1 (see --help)"
            ;;
        *)
            die "unexpected extra argument: $1 (see --help)"
            ;;
    esac
done

if [ -n "$jobs" ] && ! [[ "$jobs" =~ ^[1-9][0-9]*$ ]]; then
    die "invalid job count: '$jobs'"
fi
[ -x "$src/configure" ] || die "no QEMU configure script in $src (see -s/--src)"

# /build/qemu and the build directory are usually bind mounts from the host. A
# container starts as root, so building straight away would leave root-owned
# build artefacts in the host tree. When we are root, fix the ownership to the
# host user and re-execute this script as that user (same approach as
# ubuntu-kernel-build.sh).
host_uid=${HOST_UID:-$(stat -c %u -- "$src")}
host_gid=${HOST_GID:-$(stat -c %g -- "$src")}
if ! [[ "$host_uid" =~ ^[0-9]+$ && "$host_gid" =~ ^[0-9]+$ ]]; then
    die "invalid HOST_UID/HOST_GID: '$host_uid:$host_gid'"
fi

if [ "$host_uid" -ne 0 ] && [ "$(id -u)" -eq 0 ] && [ "${BUILD_AS_ROOT:-0}" != 1 ]; then
    command -v setpriv >/dev/null 2>&1 ||
        die "setpriv not found (needed to switch to ${host_uid}:${host_gid}); set BUILD_AS_ROOT=1 to build as root"

    log "preparing ownership ${host_uid}:${host_gid}"
    for dir in "$src" "$build_dir"; do
        [ -e "$dir" ] || continue
        # A recursive chown over a whole QEMU tree is slow, so only do it when
        # something is actually owned by somebody else. The normal case -- a
        # tree already owned by the host user -- is a cheap no-op.
        if [ -n "$(find "$dir" -xdev \( ! -uid "$host_uid" -o ! -gid "$host_gid" \) -print -quit 2>/dev/null)" ]; then
            log "chown -R ${host_uid}:${host_gid} ${dir}"
            chown -R "${host_uid}:${host_gid}" "$dir"
        fi
    done

    # Create the build directory while we are still root: its parent may be a
    # container path the build user cannot write to (e.g. /build with the
    # default settings), and the fresh directory would be root-owned anyway.
    if [ ! -d "$build_dir" ]; then
        mkdir -p -- "$build_dir"
        chown "${host_uid}:${host_gid}" -- "$build_dir"
    fi

    self=/usr/local/bin/qemu-build.sh
    if [ ! -r "$self" ]; then
        self=$(readlink -f -- "${BASH_SOURCE[0]:-}")
        if [ -z "$self" ] || [ ! -r "$self" ]; then
            die "cannot re-execute as ${host_uid}:${host_gid}: script is not readable"
        fi
    fi

    log "switching to ${host_uid}:${host_gid} for the build"
    exec setpriv --reuid "$host_uid" --regid "$host_gid" --clear-groups \
        env HOME=/tmp "$self" ${orig_args[@]+"${orig_args[@]}"}
fi

log "creating build directory $build_dir"
mkdir -p -- "$build_dir"
cd -- "$build_dir"

log "configure ${configure_args[*]:-(no extra options)}"
"$src/configure" ${configure_args[@]+"${configure_args[@]}"}

# The build system is chosen by configure: ninja if it is installed (always
# the case in this image), plain make otherwise.
if command -v ninja >/dev/null 2>&1; then
    build=(ninja)
    [ -z "$jobs" ] || build+=(-j "$jobs")
else
    build=(make -j "${jobs:-$(nproc)}")
fi

log "building: ${build[*]}"
"${build[@]}"

log "done: $(pwd)"
