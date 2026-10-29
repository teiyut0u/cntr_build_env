#!/usr/bin/env bash
#
# Build an Ubuntu kernel inside the ubuntu_kernel_builder:<ubuntu-release>-<kernel-release> image.
#
# Usage:
#   ./scripts/build_target.sh [source-dir] [-k <kernel-release>] [-r <ubuntu-release>] [-o <output-dir>] [-l <flavours>] [-i]
#
# source-dir is optional:
#   * given   -> bind-mounted read-write at /build/linux
#   * omitted -> `apt source linux-image-unsigned-<kernel-release>` is run
#                inside the container
#
# By default the build starts immediately.  Pass -i/--interactive to get a
# shell inside the container first (in the prepared source tree); leaving it
# starts the build, 'exit 1' aborts.
#
# The resulting .deb packages are copied to <output-dir>
# (default: ./debs/<kernel-release>) on the host.

set -euo pipefail

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage: build_target.sh [source-dir] [options]

Build an Ubuntu kernel with fakeroot debian/rules binary inside the
ubuntu_kernel_builder:<ubuntu-release>-<kernel-release> image and copy the
.deb files out.

Arguments:
  [source-dir]              Optional host path to the extracted kernel source
                            tree itself, i.e. the linux-X.Y.Z directory that
                            `apt source` produces (must contain debian/). It
                            is mounted at /build/linux. Without it the source
                            is fetched with `apt source` inside the container.

Options:
  -k, --kernel-release KR   Kernel release (default: uname -r).
  -r, --ubuntu-release REL  Ubuntu release part of the image tag, as passed
                            to scripts/build_image.sh -r (e.g. noble, 24.04).
                            Default: auto-detect from local images matching
                            the kernel release.
  -o, --output DIR          Host directory for the .deb files
                            (default: ./debs/<kernel-release>).
  -j, --jobs N              Parallel build jobs (default: nproc).
  -l, --flavours LIST       Only build these flavour(s), overriding the
                            `flavours` variable from debian.<kernel>/rules.d/
                            <arch>.mk, e.g. -l cxltest or -l "generic cxltest"
                            (commas work too). Default: whatever
                            debian/rules lists (i.e. build every flavour).
  -i, --interactive         Open a shell inside the container before building
                            (in the prepared source tree); leaving the shell
                            starts the build, 'exit 1' aborts it. Requires a
                            terminal. Without this option the build runs
                            immediately.
      --root                In mount mode, skip the ownership fix and build
                            as root. Default: chown the mounted tree and
                            /output to HOST_UID:HOST_GID, then build as that
                            user so file ownership stays correct.
  -h, --help                Show this help and exit.

Environment:
  DOCKER                    Container engine to use (default: docker).
  KERNEL_RELEASE            Default for --kernel-release.
  JOBS                      Default for --jobs.
  FLAVOURS                  Default for --flavours.

Examples:
  ./scripts/build_target.sh ~/src/linux -k 6.8.0-45-generic
  ./scripts/build_target.sh ~/src/linux -k 6.8.0-45-generic -i
  ./scripts/build_target.sh -k 6.8.0-45-generic -r noble
  ./scripts/build_target.sh ~/src/linux -k 7.0.0-34-generic -l cxltest
  ./scripts/build_target.sh ~/src/linux -k 7.0.0-14-generic -o /tmp/debs
EOF
}

docker_bin=${DOCKER:-docker}
kernel_release=${KERNEL_RELEASE:-$(uname -r)}
jobs=${JOBS:-$(nproc)}
ubuntu_release=""
source_dir=""
output_dir=""
flavours_arg=${FLAVOURS:-}
as_root=0
interactive=0

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        -k|--kernel-release)
            [ $# -ge 2 ] || die "$1 requires an argument"
            kernel_release=$2
            shift 2
            ;;
        -r|--ubuntu-release)
            [ $# -ge 2 ] || die "$1 requires an argument"
            ubuntu_release=$2
            shift 2
            ;;
        -o|--output)
            [ $# -ge 2 ] || die "$1 requires an argument"
            output_dir=$2
            shift 2
            ;;
        -j|--jobs)
            [ $# -ge 2 ] || die "$1 requires an argument"
            jobs=$2
            shift 2
            ;;
        -l|--flavours)
            [ $# -ge 2 ] || die "$1 requires an argument"
            flavours_arg=$2
            shift 2
            ;;
        -i|--interactive)
            interactive=1
            shift
            ;;
        --root)
            as_root=1
            shift
            ;;
        --)
            shift
            break
            ;;
        -*)
            die "unknown option: $1 (see --help)"
            ;;
        *)
            [ -z "$source_dir" ] || die "unexpected extra argument: $1"
            source_dir=$1
            shift
            ;;
    esac
done

# Positional arguments after `--`.
for arg in "$@"; do
    [ -z "$source_dir" ] || die "unexpected extra argument: $arg"
    source_dir=$arg
done

if ! [[ "$kernel_release" =~ ^[0-9][A-Za-z0-9.+~_-]*$ ]]; then
    die "invalid kernel release: '$kernel_release'"
fi
if [ -n "$ubuntu_release" ] && ! [[ "$ubuntu_release" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    die "invalid Ubuntu release: '$ubuntu_release'"
fi
if ! [[ "$jobs" =~ ^[1-9][0-9]*$ ]]; then
    die "invalid job count: '$jobs'"
fi

if [ -n "$flavours_arg" ]; then
    # Accept "a b", "a,b" and "a, b"; debian/rules wants a space separated list.
    flavours_normalised=""
    for flavour in ${flavours_arg//,/ }; do
        if ! [[ "$flavour" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
            die "invalid flavour: '$flavour'"
        fi
        flavours_normalised+="${flavours_normalised:+ }$flavour"
    done
    flavours_arg=$flavours_normalised
fi

if [ -n "$source_dir" ]; then
    [ -d "$source_dir" ] || die "source directory not found: $source_dir"
    source_dir=$(cd -- "$source_dir" && pwd -P)
fi

command -v "$docker_bin" >/dev/null 2>&1 ||
    die "container engine not found: $docker_bin (set DOCKER=... to override)"

if [ -n "$ubuntu_release" ]; then
    image="ubuntu_kernel_builder:${ubuntu_release}-${kernel_release}"
    if ! "$docker_bin" image inspect "$image" >/dev/null 2>&1; then
        die "image not found: $image (build it with ./scripts/build_image.sh $kernel_release -r $ubuntu_release)"
    fi
else
    # No -r given: look for a local image whose tag is
    # <ubuntu-release>-<kernel-release>.
    matches=()
    while IFS= read -r tag; do
        case "$tag" in
            ''|'<none>') continue ;;
        esac
        case "$tag" in
            *-"$kernel_release") matches+=("$tag") ;;
        esac
    done < <("$docker_bin" image ls ubuntu_kernel_builder --format '{{.Tag}}' 2>/dev/null || true)

    if [ ${#matches[@]} -eq 0 ]; then
        die "no local image matches kernel release $kernel_release; build it first, e.g. ./scripts/build_image.sh $kernel_release -r <ubuntu-release>"
    fi
    if [ ${#matches[@]} -gt 1 ]; then
        printf 'multiple images match kernel release %s:\n' "$kernel_release" >&2
        printf '  ubuntu_kernel_builder:%s\n' "${matches[@]}" >&2
        die "pick one with -r/--ubuntu-release"
    fi
    image="ubuntu_kernel_builder:${matches[0]}"
fi

if [ -z "$output_dir" ]; then
    output_dir="debs/${kernel_release}"
fi
mkdir -p -- "$output_dir"
output_dir=$(cd -- "$output_dir" && pwd -P)

mounts=(-v "${output_dir}:/output")
if [ -n "$source_dir" ]; then
    mounts+=(-v "${source_dir}:/build/linux")
fi

flavours_env=()
if [ -n "$flavours_arg" ]; then
    flavours_env=(-e "BUILD_FLAVOURS=${flavours_arg}")
fi

printf 'image      : %s\n' "$image"
printf 'source     : %s\n' "${source_dir:-apt source linux-image-unsigned-${kernel_release}}"
printf 'output     : %s\n' "$output_dir"
printf 'jobs       : %s\n' "$jobs"
printf 'flavours   : %s\n' "${flavours_arg:-<all listed in debian/rules>}"
printf 'mode       : %s\n' "$([ "$interactive" = 1 ] && echo 'interactive (shell before build)' || echo batch)"
printf '\n'

tty_args=()
if [ "$interactive" = 1 ]; then
    if [ -t 0 ] && [ -t 1 ]; then
        tty_args=(-it)
    else
        die "interactive mode (-i/--interactive) needs a terminal (stdin and stdout must be a TTY)"
    fi
fi

"$docker_bin" run --rm \
    ${tty_args[@]+"${tty_args[@]}"} \
    ${mounts[@]+"${mounts[@]}"} \
    -e "KERNEL_RELEASE=${kernel_release}" \
    -e "SOURCE_MOUNTED=$([ -n "$source_dir" ] && echo 1 || echo 0)" \
    -e "INTERACTIVE=${interactive}" \
    ${flavours_env[@]+"${flavours_env[@]}"} \
    -e "BUILD_AS_ROOT=${as_root}" \
    -e "HOST_UID=$(id -u)" \
    -e "HOST_GID=$(id -g)" \
    -e "CONCURRENCY_LEVEL=${jobs}" \
    -e "DEB_BUILD_OPTIONS=parallel=${jobs}" \
    -w /build \
    "$image" /usr/local/bin/ubuntu-kernel-build.sh

count=$(find "$output_dir" -maxdepth 1 -type f -name '*.deb' | wc -l)
printf '\nbuilt %s .deb package(s) in %s\n' "$count" "$output_dir"
