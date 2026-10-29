#!/usr/bin/env bash
#
# Render Dockerfile.template for an Ubuntu release and build the matching QEMU
# build image (skip the build with --no-build).
#
# Usage:
#   ./build_image.sh [-r <ubuntu-release>] [--no-build] [-- <docker build options...>]
#
# Both the Dockerfile and the image tag are derived from the arguments:
#   ./Dockerfile                       qemu_builder:<ubuntu-release>

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
template="${script_dir}/Dockerfile.template"
dockerfile="${script_dir}/Dockerfile"
helper="${script_dir}/build_in_container.sh"
docker_bin=${DOCKER:-docker}
image_prefix=qemu_builder

ubuntu_release=latest

usage() {
    cat <<'EOF'
Usage: build_image.sh [options] [-- docker build ...]

Render Dockerfile.template for one Ubuntu release and build
qemu_builder:<ubuntu-release>. The QEMU source is not downloaded; the image
only contains the build environment.

Options:
  -r, --ubuntu-release REL  Ubuntu release or codename used as base image
                            (e.g. noble, 24.04, plucky). Default: latest.
      --no-build            Only render the Dockerfile.
  -h, --help                Show this help and exit.

Environment:
  DOCKER                    Container engine to use (default: docker).

Examples:
  ./build_image.sh
  ./build_image.sh -r 24.04
  ./build_image.sh -r plucky -- --pull
  ./build_image.sh --no-build
EOF
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

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
            die "unexpected extra argument: $1 (see --help)"
            ;;
    esac
done

# Everything after `--` is forwarded to `docker build`.
if [ "$passthrough" = 1 ]; then
    extra_args=("$@")
else
    [ $# -eq 0 ] || die "unexpected extra argument: $1 (put docker build options after --)"
fi

if ! [[ "$ubuntu_release" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    die "invalid Ubuntu release: '$ubuntu_release'"
fi

[ -f "$template" ] || die "template not found: $template"
[ -f "$helper" ] || die "build script not found: $helper"
grep -q '__UBUNTU_RELEASE__' "$template" ||
    die "template has no __UBUNTU_RELEASE__ placeholder: $template"

tmp=$(mktemp "${dockerfile}.XXXXXX")
trap 'rm -f -- "$tmp"' EXIT

sed -e "s|__UBUNTU_RELEASE__|${ubuntu_release}|g" "$template" >"$tmp"

if grep -q '__[A-Z_]*__' "$tmp"; then
    die "unsubstituted placeholder left in the rendered Dockerfile: $(grep -o '__[A-Z_]*__' "$tmp" | sort -u | tr '\n' ' ')"
fi

chmod 0644 "$tmp"
mv -f -- "$tmp" "$dockerfile"
trap - EXIT

image="${image_prefix}:${ubuntu_release}"

printf 'wrote %s\n' "$dockerfile"
printf '  ubuntu release : %s\n' "$ubuntu_release"
printf '  image tag      : %s\n' "$image"

if [ "$no_build" = 1 ]; then
    exit 0
fi

command -v "$docker_bin" >/dev/null 2>&1 ||
    die "container engine not found: $docker_bin (set DOCKER=... to override)"

printf '\nbuilding %s\n' "$image"
"$docker_bin" build -t "$image" -f "$dockerfile" \
    ${extra_args[@]+"${extra_args[@]}"} "$script_dir"

printf '\nbuilt %s\n' "$image"
