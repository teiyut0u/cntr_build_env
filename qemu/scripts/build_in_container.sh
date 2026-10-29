#!/usr/bin/env bash
#
# Build QEMU inside the qemu_builder image (installed as
# /usr/local/bin/qemu-build.sh).
#
# Environment:
#   JOBS  default for -j/--jobs

set -euo pipefail

src=/build/qemu
build_dir=/build/qemu/build
jobs=${JOBS:-}
configure_args=()

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
  docker run --rm -v ~/src/qemu:/build/qemu qemu_builder:latest \
      qemu-build.sh -j 8 -- --target-list=x86_64-softmmu

  # build somewhere else
  qemu-build.sh -b /build/out -- --enable-debug
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
