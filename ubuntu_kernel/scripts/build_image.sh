#!/usr/bin/env bash
#
# Render Dockerfile.template for a given Ubuntu kernel release and build the
# matching build image (skip the build with --no-build).
#
# Usage:
#   ./scripts/build_image.sh <kernel-release> [-r <ubuntu-release>] [-o <Dockerfile>]
#                    [--no-build] [-- <docker build options...>]
#
# <kernel-release> is mandatory and is substituted for __KERNEL_RELEASE__ in
# the template (it is the value `uname -r` prints on the target machine).
#
# The image tag is derived from the arguments, not re-parsed from the rendered
# Dockerfile: ubuntu_kernel_builder:<ubuntu-release>-<kernel-release>.

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
template="${script_dir}/Dockerfile.template"
docker_bin=${DOCKER:-docker}

usage() {
    cat <<'EOF'
Usage: build_image.sh <kernel-release> [options] [-- docker build ...]

Render Dockerfile.template for one Ubuntu kernel release and build
ubuntu_kernel_builder:<ubuntu-release>-<kernel-release>. The kernel source is
not downloaded; the image only contains the build environment.

Arguments:
  <kernel-release>          Required. e.g. 6.8.0-45-generic, 7.0.0-14-generic

Options:
  -r, --ubuntu-release REL  Ubuntu release or codename whose archive carries
                            that kernel (e.g. noble, 24.04, resolute).
                            Default: inferred from the kernel version.
  -o, --output DOCKERFILE   Path of the Dockerfile to write
                            (default: ./Dockerfile). Its directory is used as
                            the docker build context.
      --no-build            Only render the Dockerfile.
  -h, --help                Show this help and exit.

Environment:
  DOCKER                    Container engine to use (default: docker).

Examples:
  ./scripts/build_image.sh 6.8.0-45-generic
  ./scripts/build_image.sh 6.8.0-45-generic -- --pull
  ./scripts/build_image.sh 7.0.0-14-generic -r resolute -o Dockerfile.resolute
  ./scripts/build_image.sh 7.0.0-14-generic --no-build
EOF
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

# Best-effort mapping of a kernel version to the Ubuntu release that ships it.
ubuntu_release_for_kernel() {
    local kernel_release=$1
    local major minor
    major=${kernel_release%%.*}
    minor=${kernel_release#*.}
    minor=${minor%%.*}

    case "${major}.${minor}" in
        6.8)  echo noble ;;      # 24.04 LTS
        6.11) echo oracular ;;   # 24.10
        6.14) echo plucky ;;     # 25.04
        6.17) echo questing ;;   # 25.10
        7.0)  echo resolute ;;   # 26.04 LTS
        *)    return 1 ;;
    esac
}

kernel_release=""
ubuntu_release=""
dockerfile="./Dockerfile"
no_build=0
passthrough=0
extra_args=()

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        -r|--ubuntu-release)
            [ $# -ge 2 ] || die "$1 requires one argument"
            ubuntu_release=$2
            shift 2
            ;;
        -o|--output)
            [ $# -ge 2 ] || die "$1 requires one argument"
            dockerfile=$2
            shift 2
            ;;
        --no-build)
            no_build=1
            shift
            ;;
        --)
            shift
            passthrough=1
            break
            ;;
        -*)
            die "unknown option: $1 (see --help)"
            ;;
        *)
            [ -z "$kernel_release" ] || die "unexpected extra argument: $1"
            kernel_release=$1
            shift
            ;;
    esac
done

[ -n "$kernel_release" ] || {
    usage >&2
    die "the target kernel release is required"
}
# Everything after `--` is forwarded to `docker build`.
if [ "$passthrough" = 1 ]; then
    extra_args=("$@")
else
    [ $# -eq 0 ] || die "unexpected extra argument: $1 (put docker build options after --)"
fi

# Keep the value safe for sed and for use inside the Dockerfile.
if ! [[ "$kernel_release" =~ ^[0-9][A-Za-z0-9.+~_-]*$ ]]; then
    die "invalid kernel release: '$kernel_release' (expected e.g. 6.8.0-45-generic)"
fi

[ -f "$template" ] || die "template not found: $template"
grep -q '__KERNEL_RELEASE__' "$template" ||
    die "template has no __KERNEL_RELEASE__ placeholder: $template"

if [ -z "$ubuntu_release" ]; then
    ubuntu_release=$(ubuntu_release_for_kernel "$kernel_release") || {
        die "cannot infer the Ubuntu release for kernel '$kernel_release'; pass it explicitly with -r <codename|version>"
    }
fi

if ! [[ "$ubuntu_release" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    die "invalid Ubuntu release: '$ubuntu_release'"
fi

dockerfile_dir=$(dirname -- "$dockerfile")
mkdir -p -- "$dockerfile_dir"
dockerfile_dir=$(cd -- "$dockerfile_dir" && pwd)
dockerfile="${dockerfile_dir}/$(basename -- "$dockerfile")"

tmp=$(mktemp "${dockerfile}.XXXXXX")
trap 'rm -f -- "$tmp"' EXIT

sed -e "s|__KERNEL_RELEASE__|${kernel_release}|g" \
    -e "s|__UBUNTU_RELEASE__|${ubuntu_release}|g" \
    "$template" >"$tmp"

if grep -q '__[A-Z_]*__' "$tmp"; then
    die "unsubstituted placeholder left in the rendered Dockerfile: $(grep -o '__[A-Z_]*__' "$tmp" | sort -u | tr '\n' ' ')"
fi

chmod 0644 "$tmp"
mv -f -- "$tmp" "$dockerfile"
trap - EXIT

printf 'wrote %s\n' "$dockerfile"
printf '  kernel release : %s\n' "$kernel_release"
printf '  ubuntu release : %s\n' "$ubuntu_release"
printf '  image tag      : ubuntu_kernel_builder:%s-%s\n' "$ubuntu_release" "$kernel_release"

if [ "$no_build" = 1 ]; then
    exit 0
fi

command -v "$docker_bin" >/dev/null 2>&1 ||
    die "container engine not found: $docker_bin (set DOCKER=... to override)"

image_tag="${ubuntu_release}-${kernel_release}"
if [ ${#image_tag} -gt 128 ]; then
    die "image tag is longer than 128 characters: $image_tag"
fi
image="ubuntu_kernel_builder:${image_tag}"
context="$dockerfile_dir"

# Dockerfile.template copies build_in_container.sh into the image.  It
# must be in the build context; stage a copy when the Dockerfile is rendered
# somewhere else and remove it again afterwards.
helper=build_in_container.sh
staged_helper=""
cleanup() { [ -z "$staged_helper" ] || rm -f -- "$staged_helper"; }
trap cleanup EXIT

if [ ! -f "$context/$helper" ]; then
    [ -f "$script_dir/$helper" ] || die "build script not found: $script_dir/$helper"
    cp -- "$script_dir/$helper" "$context/$helper"
    staged_helper="$context/$helper"
    printf 'staged     : %s\n' "$staged_helper"
fi

printf '\nbuilding %s\n' "$image"
# Forward any extra options after the fixed ones.
"$docker_bin" build -t "$image" -f "$dockerfile" \
    ${extra_args[@]+"${extra_args[@]}"} "$context"

printf '\nbuilt %s\n' "$image"
