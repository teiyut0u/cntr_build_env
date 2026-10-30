#!/usr/bin/env bash
#
# Build QEMU inside the qemu_builder image (installed as
# /usr/local/bin/qemu-build.sh).
#
# Environment:
#   JOBS    default for -j/--jobs
#   INSTALL_DIR
#           default for -i/--install-dir (QEMU's --prefix)
#   HOST_UID/HOST_GID
#           owner for the mounted source tree, the build directory and the
#           install directory. When the container starts as root (the
#           default), the ownership of all three is fixed to this user -- by
#           default the owner of the source tree --
#           and the build is re-executed as that user, so no root-owned files
#           are left behind in the host tree.
#   BUILD_AS_ROOT
#           1 to skip the ownership fix and build as root

set -euo pipefail

src=/build/qemu
build_dir=/build/qemu/build
install_dir=${INSTALL_DIR:-/install}
# prefix the messages report on; replaced by the --prefix value when the caller
# overrides it through the configure arguments.
install_prefix=$install_dir
jobs=${JOBS:-}
configure_args=()
# -i/--install-dir is forwarded to configure as --prefix, unless the caller
# passes --prefix after `--`, which takes precedence.
is_prefix_given=0
is_install_dir_given=0

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
  -i, --install-dir DIR
                       QEMU's install prefix: configure is run with
                       --prefix=DIR, so `ninja install` puts the files
                       directly into DIR (DIR/bin/qemu-system-*, ...);
                       DIR is created if missing. Default: $INSTALL_DIR,
                       i.e. /install. Added to the configure command line as
                       --prefix=DIR; a --prefix passed after `--` wins.
  --                   everything after it is passed to <src>/configure.
  -h, --help           show this help and exit.

Examples:
  # build in the default place (source mounted at /build/qemu), installing
  # into the default /install
  docker run --rm -v ~/src/qemu:/build/qemu -v ~/qemu-inst:/install \
      -e HOST_UID=$(id -u) -e HOST_GID=$(id -g) qemu_builder:latest \
      qemu-build.sh -j 8 -- --target-list=x86_64-softmmu

  # build somewhere else and install into a custom directory
  docker run --rm -v ~/src/qemu:/build/qemu -v ~/qemu-opt:/opt/qemu \
      -e HOST_UID=$(id -u) -e HOST_GID=$(id -g) qemu_builder:latest \
      qemu-build.sh -b /build/out -i /opt/qemu -- --enable-debug

After the build `ninja install` (or `make install`) runs without DESTDIR, so
QEMU is installed exactly under the install prefix (/install by default):
/install/bin/qemu-system-x86_64, /install/share/qemu/... The prefix comes from
-i/--install-dir, unless a --prefix is passed after `--`, which wins (a note
is printed when both are given). Note that the prefix is compiled in, so a
relocated tree is still looked up under the prefix at runtime (QEMU also
probes paths relative to the binary).

Mount the source tree read-write: the build writes into it (and into the
build directory, which defaults to <src>/build) as the host user, so the
resulting files keep their normal ownership. Mount a host directory at the
install directory (-i, default /install) to get the installed tree out of
the container; without it the installed files are thrown away with it.
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
        -i|--install-dir)
            [ $# -ge 2 ] || die "$1 requires an argument"
            install_dir=$2
            is_install_dir_given=1
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
[ -n "$install_dir" ] || die "empty install directory (see -i/--install-dir)"

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
    for dir in "$src" "$build_dir" "$install_dir"; do
        [ -e "$dir" ] || continue
        # A recursive chown over a whole QEMU tree is slow, so only do it when
        # something is actually owned by somebody else. The normal case -- a
        # tree already owned by the host user -- is a cheap no-op.
        if [ -n "$(find "$dir" -xdev \( ! -uid "$host_uid" -o ! -gid "$host_gid" \) -print -quit 2>/dev/null)" ]; then
            log "chown -R ${host_uid}:${host_gid} ${dir}"
            chown -R "${host_uid}:${host_gid}" "$dir"
        fi
    done

    # Create the build and install directories while we are still root: their
    # parents may be container paths the build user cannot write to (e.g. /
    # with the default settings), and the fresh directories would be
    # root-owned anyway.
    for dir in "$build_dir" "$install_dir"; do
        if [ ! -d "$dir" ]; then
            mkdir -p -- "$dir"
            chown "${host_uid}:${host_gid}" -- "$dir"
        fi
    done

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

# detect a --prefix passed through to configure; it wins over
# -i/--install-dir (only a note is printed in that case).
for arg in ${configure_args[@]+"${configure_args[@]}"}; do
    case "$arg" in
        --prefix|--prefix=*) is_prefix_given=1 ;;
    esac
done

if [ "$is_prefix_given" = 1 ]; then
    if [ "$is_install_dir_given" = 1 ]; then
        printf 'note: --prefix given after "--" wins over -i/--install-dir %s\n' \
            "$install_dir" >&2
    fi
    # Only for the messages: pick the value of the winning --prefix.
    prev=
    for arg in ${configure_args[@]+"${configure_args[@]}"}; do
        case "$arg" in
            --prefix=*) install_prefix=${arg#--prefix=} ;;
            *) [ "$prev" != --prefix ] || install_prefix=$arg ;;
        esac
        prev=$arg
    done
else
    install_prefix=$install_dir
    configure_args=(--prefix "$install_dir" ${configure_args[@]+"${configure_args[@]}"})
fi

# The install prefix created above is only needed when -i/--install-dir is what
# configure gets; a --prefix passed after `--` replaces it.
if [ "$is_prefix_given" = 0 ]; then
    log "creating install directory $install_dir"
    mkdir -p -- "$install_dir"
fi

log "configure ${configure_args[*]}"
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

# No DESTDIR here: the install prefix was set by configure (-i/--install-dir
# or, if given, the --prefix passed after `--`).
log "installing into $install_prefix"
"${build[@]}" install

log "done: build in $(pwd), installed into $install_prefix"
