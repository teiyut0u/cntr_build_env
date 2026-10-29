#!/usr/bin/env bash
#
# Runs *inside* the ubuntu_kernel_builder image (installed as
# /usr/local/bin/ubuntu-kernel-build.sh).
#
# The kernel source is either mounted at /build/linux (SOURCE_MOUNTED=1) or
# fetched with `apt source` (SOURCE_MOUNTED=0, the tree is unpacked into
# /build and /build/linux is created as a symlink to it).  The resulting .deb
# files are written by Ubuntu to the parent of the source tree, i.e. /build,
# and are copied to /output.
#
# Environment:
#   KERNEL_RELEASE     required, e.g. 7.0.0-34-generic
#   SOURCE_MOUNTED     1 if a source tree is bind-mounted at /build/linux
#   CONCURRENCY_LEVEL  parallel build jobs (passed to debian/rules)
#   DEB_BUILD_OPTIONS  should contain parallel=<jobs>
#   BUILD_FLAVOURS     optional space separated flavour list; when set it is
#                      passed to debian/rules as `flavours=...`, overriding the
#                      `flavours` variable from debian.<kernel>/rules.d/<arch>.mk
#   HOST_UID/HOST_GID  owner for the mounted tree and /output. In mount mode
#                      the build is re-executed as this user (default: the
#                      owner of /build/linux).
#   BUILD_AS_ROOT      1 to skip the ownership fix and build as root
#   INTERACTIVE        1 to open a shell in the prepared source tree before
#                      building.  Leaving the shell starts the build, exiting
#                      with a non-zero status aborts it.  Ignored when stdin
#                      is not a terminal.
#
# Usage (normally done by build_target.sh on the host):
#   docker run --rm -it -v <src>:/build/linux -v <out>:/output \
#       -e SOURCE_MOUNTED=1 -e HOST_UID=$(id -u) -e HOST_GID=$(id -g) \
#       ubuntu_kernel_builder:<release>-<kernel> ubuntu-kernel-build.sh

set -euo pipefail

: "${KERNEL_RELEASE:?KERNEL_RELEASE is not set}"

export do_linux_main_modules_depends=false
export DEBIAN_FRONTEND=noninteractive

log() { printf '\n>>> %s\n' "$*"; }

src=/build/linux
if [ "${SOURCE_MOUNTED:-0}" = 1 ]; then
    # The host path (e.g. linux-7.0.0, the directory apt source unpacks) must
    # be the source tree itself, not its parent directory.
    if [ ! -d "$src/debian" ]; then
        printf 'error: mounted source is not a kernel source tree (no %s/debian)\n' "$src" >&2
        printf 'hint: mount the extracted tree itself, e.g. .../linux-7.0.0\n' >&2
        exit 1
    fi

    # Build as the host user so the source tree and /output keep the right
    # ownership.  The container starts as root (needed to fix ownership),
    # then re-executes this script via setpriv as HOST_UID:HOST_GID.
    host_uid=${HOST_UID:-$(stat -c %u -- "$src")}
    host_gid=${HOST_GID:-$(stat -c %g -- "$src")}
    if ! [[ "$host_uid" =~ ^[0-9]+$ && "$host_gid" =~ ^[0-9]+$ ]]; then
        printf 'error: invalid HOST_UID/HOST_GID: %s:%s\n' "$host_uid" "$host_gid" >&2
        exit 1
    fi

    if [ "$host_uid" -ne 0 ] && [ "$(id -u)" -eq 0 ] && [ "${BUILD_AS_ROOT:-0}" != 1 ]; then
        log "preparing ownership ${host_uid}:${host_gid}"

        if [ -n "$(find "$src" -xdev \( ! -uid "$host_uid" -o ! -gid "$host_gid" \) -print -quit 2>/dev/null)" ]; then
            log "chown -R ${host_uid}:${host_gid} ${src}"
            chown -R "${host_uid}:${host_gid}" "$src"
        fi
        chown -R "${host_uid}:${host_gid}" /output

        log "switching to ${host_uid}:${host_gid} for the build"
        exec setpriv --reuid "$host_uid" --regid "$host_gid" --clear-groups \
            env HOME=/tmp /usr/local/bin/ubuntu-kernel-build.sh "$@"
    fi
else
    log "fetching source: apt source linux-image-unsigned-${KERNEL_RELEASE}"
    cd /build
    apt-get update
    apt-get source "linux-image-unsigned-${KERNEL_RELEASE}"
    src=$(find /build -maxdepth 1 -mindepth 1 -type d -name 'linux-*' \
            -printf '%T@ %p\n' | sort -nr | tail -n1 | cut -d' ' -f2-)
    if [ -z "${src}" ] || [ ! -d "${src}/debian" ]; then
        printf 'error: could not find the unpacked kernel source under /build\n' >&2
        exit 1
    fi
    # Same layout as the bind-mount case: /build/linux is the source tree
    # (here a symlink to the directory unpacked by apt source, e.g.
    # /build/linux-7.0.0).  Ubuntu writes the .deb files to /build either way.
    ln -sfn -- "$src" /build/linux
    src=/build/linux
    log "linked /build/linux -> $(readlink -f -- "$src")"
fi

cd "$src"
log "kernel source: $src"

chmod a+x debian/scripts/* debian/scripts/misc/* 2>/dev/null || true

# Optional pause before building: the tree is already usable (owned by the
# host user in mount mode, sources fetched in apt source mode), so this is
# where config / flavour / changelog changes are made.  `debian/rules clean`
# below regenerates debian/control, so changing the flavour here works too.
if [ "${INTERACTIVE:-0}" = 1 ]; then
    if [ ! -t 0 ]; then
        log "INTERACTIVE=1 but stdin is not a terminal; building without a shell"
    else
        cat <<EOF

>>> interactive mode -- nothing has been built yet (kernel source: $src)

    config : edit debian.master/config/annotations (recommended), or run
             fakeroot debian/rules editconfigs
             note: editconfigs walks *all* arch/flavour entries of the
             annotations "# FLAVOUR:" header and aborts importing the ones
             without a cross toolchain; trim that header to the arch you
             build, or use "annotations --arch ... --flavour ... --update"
    name   : debian.master/changelog (ABI bump),
             debian.master/rules.d/<arch>.mk (flavours),
             debian.master/control.d/vars.<flavour>, annotations "# FLAVOUR:"
             (pass -l/--flavours to build_target.sh to build only some of them)
    build  : leave the shell (exit / Ctrl-D) to run
             'fakeroot debian/rules clean && fakeroot debian/rules binary'
             'exit 1' aborts without building

EOF
        if ! bash -i; then
            printf '\n>>> interactive session aborted, nothing was built\n' >&2
            exit 1
        fi
        log "interactive session finished, starting the build"
    fi
fi

log "fakeroot debian/rules clean"
fakeroot debian/rules clean

# BUILD_FLAVOURS (set by build_target.sh -l/--flavours) overrides the `flavours`
# variable from debian.<kernel>/rules.d/<arch>.mk; make command line variables
# win over the ones assigned in the makefiles. A list with spaces is kept as a
# single (quoted) argument, which make accepts as one variable assignment.
flavour_args=()
if [ -n "${BUILD_FLAVOURS:-}" ]; then
    flavour_args+=("flavours=${BUILD_FLAVOURS}")
fi

log "fakeroot debian/rules binary ${flavour_args[*]:-(default flavours)} (CONCURRENCY_LEVEL=${CONCURRENCY_LEVEL:-1})"
fakeroot debian/rules binary ${flavour_args[@]+"${flavour_args[@]}"}

# Ubuntu writes the .deb files one level above the source tree.  In both
# modes that directory is /build: container-internal, mode 1777, so the build
# user can create files there without another chown.  Only the host-backed
# paths -- the mounted source tree and /output -- need ownership fixes.
parent=$(dirname -- "$src")
log "collecting .deb packages from $parent"

shopt -s nullglob
debs=("$parent"/*.deb "$parent"/*.ddeb)
shopt -u nullglob

if [ ${#debs[@]} -eq 0 ]; then
    printf 'error: build finished but no .deb files were found in %s\n' "$parent" >&2
    exit 1
fi

cp -v -- "${debs[@]}" /output/

if [ "$(id -u)" -eq 0 ] && [ -n "${HOST_UID:-}" ] && [ -n "${HOST_GID:-}" ]; then
    chown -R "${HOST_UID}:${HOST_GID}" /output
fi

log "done"
shopt -s nullglob
ls -lh /output/*.deb /output/*.ddeb
shopt -u nullglob
