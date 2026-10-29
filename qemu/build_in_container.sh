#!/usr/bin/env bash
#
# Build QEMU inside the qemu_builder image (installed as
# /usr/local/bin/qemu-build.sh).
#
# Usage:
#   qemu-build.sh <build-dir> [-j <jobs>] [-- <configure args...>]
#
#   <build-dir>     directory to configure and build in; created if missing.
#                   The build is out-of-tree, so mount it from the host to
#                   keep the results, e.g. -v $PWD/build:/build.
#   -j, --jobs N    parallel jobs. Default: $JOBS; if that is unset too,
#                   ninja picks its own default and make uses `nproc`.
#   --              everything after it is passed to <source>/configure.
#
# Environment:
#   QEMU_SRC        QEMU source tree inside the container (default: /src).
#   JOBS            default for -j/--jobs.
#
# Example:
#   docker run --rm -v ~/src/qemu:/src:ro -v $PWD/build:/build \
#       qemu_builder:noble \
#       qemu-build.sh /build/x86_64 -j 8 -- --target-list=x86_64-softmmu

set -euo pipefail

src=${QEMU_SRC:-/src}
build_dir=""
jobs=${JOBS:-}
configure_args=()

usage() {
    sed -n '3,23p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
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
            [ -z "$build_dir" ] || die "unexpected extra argument: $1"
            build_dir=$1
            shift
            ;;
    esac
done

[ -n "$build_dir" ] || {
    usage >&2
    die "the build directory is required"
}
if [ -n "$jobs" ] && ! [[ "$jobs" =~ ^[1-9][0-9]*$ ]]; then
    die "invalid job count: '$jobs'"
fi
[ -x "$src/configure" ] || die "no QEMU configure script in $src (set QEMU_SRC)"

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
