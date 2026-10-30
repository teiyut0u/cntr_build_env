#!/usr/bin/env bash
# copy_dl_from_cntr.sh - copy all dynamic libraries of a file out of a container.
#
# The dependency list is obtained with ldd(1) inside the container.  Every
# symlink in a dependency's symlink chain is resolved and copied as well, so
# that both the links and the real files end up in the destination directory.
#
# Examples:
#   ./copy_dl_from_cntr.sh -c test_scripts -f /bin/ls -d ./test_space/ls-libs
#   ./copy_dl_from_cntr.sh -c 1a2b3c -f /usr/bin/python3 -d /tmp/pylibs --mirror
#
set -u
set -o pipefail

PROG=${0##*/}
ENGINE=${ENGINE:-}
CONTAINER=
TARGET=
DEST=
LAYOUT=flat                 # flat | mirror
IGNORE_MISSING=0
DRY_RUN=0
VERBOSE=0
MAX_LINK_DEPTH=64

die()  { printf '%s: error: %s\n' "$PROG" "$*" >&2; exit 1; }
warn() { printf '%s: warning: %s\n' "$PROG" "$*" >&2; }
info() { printf '%s: %s\n' "$PROG" "$*" >&2; }
vlog() { [ "$VERBOSE" -eq 1 ] && info "$*"; return 0; }

usage() {
    cat <<EOF
Usage: $PROG -c CONTAINER -f FILE -d HOST_DIR [options]

Copy FILE's dynamic libraries (as reported by ldd inside CONTAINER) to HOST_DIR.

Required:
  -c, --container NAME|ID   container name or hash (running container)
  -f, --file PATH           file path *inside* the container
  -d, --dest DIR            destination directory on the host

Options:
  -e, --engine CMD          container engine to use: docker or podman
                            (default: auto-detect)
  -m, --mirror              keep the container's absolute paths under DIR
                            (e.g. DIR/usr/lib/x86_64-linux-gnu/libc.so.6)
      --flat                copy files directly into DIR (default)
      --ignore-missing      do not fail when ldd reports "not found"
  -n, --dry-run             print what would be copied, do not write anything
  -v, --verbose             verbose output
  -h, --help                show this help

In flat mode all symlink chains are copied too.  If two different container
paths have the same basename, later ones get a numeric suffix (foo.so.1,
foo.so.1.1, ...) and links are rewritten to the actual copied name.  Use
--mirror if container paths must be preserved exactly.  In both layouts the
links themselves are copied as relative links that point inside DIR, so the
copied tree is self-contained even when the original links were absolute.

The ldd output itself is parsed; linux-vdso/linux-gate pseudo libraries are
ignored.  Missing libraries cause a non-zero exit unless --ignore-missing is
given.
EOF
}

need_arg() {
    [ "$#" -ge 2 ] || die "option $1 requires an argument"
}

while [ "$#" -gt 0 ]; do
    case $1 in
        -c|--container) need_arg "$@"; CONTAINER=$2; shift 2 ;;
        -f|--file)      need_arg "$@"; TARGET=$2;    shift 2 ;;
        -d|--dest)      need_arg "$@"; DEST=$2;      shift 2 ;;
        -e|--engine)    need_arg "$@"; ENGINE=$2;    shift 2 ;;
        -m|--mirror)    LAYOUT=mirror; shift ;;
        --flat)         LAYOUT=flat;   shift ;;
        --ignore-missing) IGNORE_MISSING=1; shift ;;
        -n|--dry-run)   DRY_RUN=1; shift ;;
        -v|--verbose)   VERBOSE=1; shift ;;
        -h|--help)      usage; exit 0 ;;
        --) shift; break ;;
        -*) die "unknown option: $1 (use -h for help)" ;;
        *)  die "unexpected argument: $1 (use -h for help)" ;;
    esac
done

[ -n "$CONTAINER" ] || { usage >&2; die "missing -c/--container"; }
[ -n "$TARGET" ]    || { usage >&2; die "missing -f/--file"; }
[ -n "$DEST" ]      || { usage >&2; die "missing -d/--dest"; }
[ "${TARGET#/}" != "$TARGET" ] || die "the container path must be absolute: $TARGET"

# ---------------------------------------------------------------------------
# Container engine handling
# ---------------------------------------------------------------------------
if [ -z "$ENGINE" ]; then
    if command -v docker >/dev/null 2>&1 &&
       docker inspect "$CONTAINER" >/dev/null 2>&1; then
        ENGINE=docker
    elif command -v podman >/dev/null 2>&1 &&
         podman inspect "$CONTAINER" >/dev/null 2>&1; then
        ENGINE=podman
    else
        die "container '$CONTAINER' not found by docker or podman; use -e to choose an engine"
    fi
else
    case $ENGINE in
        docker|podman) ;;
        */*) [ -x "$ENGINE" ] || die "engine is not executable: $ENGINE" ;;
        *) command -v "$ENGINE" >/dev/null 2>&1 || die "engine not found: $ENGINE" ;;
    esac
fi

"$ENGINE" inspect "$CONTAINER" >/dev/null 2>&1 ||
    die "container not found: $CONTAINER (engine: $ENGINE)"
running=$("$ENGINE" inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || true)
[ "$running" = "true" ] || die "container is not running: $CONTAINER"
vlog "using engine: $ENGINE"

# Run a shell inside the container with one positional argument.
cexec_sh() {
    local script=$1 arg=$2
    "$ENGINE" exec "$CONTAINER" sh -c "$script" sh "$arg"
}

# Print l, f, o (other) or m (missing) for a path inside the container.
container_kind() {
    local kind
    kind=$(cexec_sh '
        if [ -L "$1" ]; then printf l
        elif [ -f "$1" ]; then printf f
        elif [ -e "$1" ]; then printf o
        else printf m
        fi' "$1") || die "failed to inspect path in container: $1"
    printf '%s' "$kind"
}

container_readlink() {
    cexec_sh 'exec readlink "$1"' "$1"
}

# Lexically normalise an absolute path without resolving symlinks.
normpath() {
    local p=$1 part
    local -a out=()
    [[ $p == /* ]] || p=/$p
    local IFS=/
    for part in $p; do
        case $part in
            ''|.) ;;
            ..) [ "${#out[@]}" -gt 0 ] && unset 'out[${#out[@]}-1]' ;;
            *) out+=("$part") ;;
        esac
    done
    printf '/%s\n' "$(IFS=/; printf '%s' "${out[*]}")"
}

path_dirname() {
    local p=$1
    case $p in
        */*) p=${p%/*}; [ -n "$p" ] || p=/ ;;
        *) p=. ;;
    esac
    printf '%s\n' "$p"
}

# Relative path from directory $1 to path $2 (both absolute, lexical).
relpath() {
    local from=$1 to=$2
    local -a f=() t=()
    local IFS=/ i=0 j out=
    read -r -a f <<< "${from#/}"
    read -r -a t <<< "${to#/}"
    while [ "$i" -lt "${#f[@]}" ] && [ "$i" -lt "${#t[@]}" ] &&
          [ "${f[$i]}" = "${t[$i]}" ]; do
        i=$((i + 1))
    done
    for ((j = i; j < ${#f[@]}; j++)); do out+="../"; done
    for ((j = i; j < ${#t[@]}; j++)); do out+="${t[$j]}/"; done
    if [ -n "$out" ]; then out=${out%/}; else out=.; fi
    printf '%s\n' "$out"
}

# ---------------------------------------------------------------------------
# Get ldd output
# ---------------------------------------------------------------------------
kind=$(container_kind "$TARGET")
case $kind in
    f|l) ;;
    m) die "file does not exist in container: $TARGET" ;;
    *) die "not a regular file in container: $TARGET" ;;
esac

vlog "running ldd on $TARGET"
ldd_out=$(cexec_sh 'LC_ALL=C exec ldd "$1"' "$TARGET" 2>&1)
ldd_rc=$?
vlog "ldd exit status: $ldd_rc"

case $ldd_out in
    *"not a dynamic executable"*|*"not a dynamic ELF executable"*)
        die "not a dynamically linked executable: $TARGET" ;;
esac

LDD_PATHS=()
LDD_MISSING=()
STATIC=0
while IFS= read -r line; do
    line=${line%$'\r'}
    # trim leading/trailing whitespace
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    [ -n "$line" ] || continue

    case $line in
        linux-vdso.so.*|linux-gate.so.*)
            continue ;;
        "statically linked")
            STATIC=1; continue ;;
        "not a dynamic executable"*)
            die "not a dynamic executable: $TARGET" ;;
    esac

    if [[ $line == *"=>"* ]]; then
        rhs=${line#*=>}
        rhs=${rhs#"${rhs%%[![:space:]]*}"}
        if [[ $rhs == "not found"* ]]; then
            soname=${line%%=>*}
            soname=${soname%"${soname##*[![:space:]]}"}
            LDD_MISSING+=("$soname")
            continue
        fi
        path=${rhs%% (*}
        path=${path%"${path##*[![:space:]]}"}
        case $path in
            /*) LDD_PATHS+=("$path") ;;
            *)  warn "unrecognised ldd line: $line" ;;
        esac
    else
        # Loader line, e.g. /lib64/ld-linux-x86-64.so.2 (0x...)
        path=${line%% (*}
        path=${path%"${path##*[![:space:]]}"}
        case $path in
            /*) LDD_PATHS+=("$path") ;;
            *)  vlog "ignoring ldd line: $line" ;;
        esac
    fi
done <<< "$ldd_out"

if [ "$STATIC" -eq 1 ] && [ "${#LDD_PATHS[@]}" -eq 0 ]; then
    die "file is statically linked (no dynamic libraries): $TARGET"
fi
if [ "$ldd_rc" -ne 0 ] && [ "${#LDD_PATHS[@]}" -eq 0 ] &&
   [ "${#LDD_MISSING[@]}" -eq 0 ]; then
    die "ldd failed for $TARGET: $ldd_out"
fi

if [ "${#LDD_MISSING[@]}" -gt 0 ]; then
    for m in "${LDD_MISSING[@]}"; do
        warn "ldd reports a missing library: $m"
    done
    [ "$IGNORE_MISSING" -eq 1 ] || die "some dynamic libraries are missing (use --ignore-missing to continue)"
fi

# de-duplicate ldd paths, keeping order
TMP_PATHS=()
declare -A ldd_seen=()
for p in "${LDD_PATHS[@]}"; do
    n=$(normpath "$p")
    [ -n "${ldd_seen[$n]+x}" ] && continue
    ldd_seen[$n]=1
    TMP_PATHS+=("$n")
done
LDD_PATHS=("${TMP_PATHS[@]}")
[ "${#LDD_PATHS[@]}" -gt 0 ] || die "ldd reported no dynamic libraries for $TARGET"

# ---------------------------------------------------------------------------
# Walk every dependency's symlink chain inside the container
# ---------------------------------------------------------------------------
ITEM_PATH=()
ITEM_KIND=()      # l = symlink, f = regular file
ITEM_TARGET=()    # raw readlink() value for symlinks
ITEM_NEXT=()      # normalised path the symlink points to
declare -A ITEM_SEEN=()
CHAIN_ERRORS=0

add_item() {
    ITEM_PATH+=("$1")
    ITEM_KIND+=("$2")
    ITEM_TARGET+=("$3")
    ITEM_NEXT+=("$4")
    ITEM_SEEN[$1]=1
}

collect_chain() {
    local cur depth=0 k target next
    local -A visiting=()
    cur=$(normpath "$1")
    while :; do
        if [ -n "${visiting[$cur]+x}" ]; then
            warn "symlink loop detected at: $cur"
            CHAIN_ERRORS=$((CHAIN_ERRORS + 1))
            return 1
        fi
        if [ -n "${ITEM_SEEN[$cur]+x}" ]; then
            return 0
        fi
        visiting[$cur]=1
        k=$(container_kind "$cur")
        case $k in
            l)
                target=$(container_readlink "$cur") ||
                    { warn "cannot read symlink: $cur"; CHAIN_ERRORS=$((CHAIN_ERRORS + 1)); return 1; }
                case $target in
                    /*) next=$(normpath "$target") ;;
                    *)  next=$(normpath "$(path_dirname "$cur")/$target") ;;
                esac
                add_item "$cur" l "$target" "$next"
                cur=$next
                depth=$((depth + 1))
                if [ "$depth" -gt "$MAX_LINK_DEPTH" ]; then
                    warn "too many symlink levels (loop?) starting at $cur"
                    CHAIN_ERRORS=$((CHAIN_ERRORS + 1))
                    return 1
                fi
                ;;
            f)
                add_item "$cur" f "" ""
                return 0
                ;;
            m)
                warn "dependency path disappeared or is dangling: $cur"
                CHAIN_ERRORS=$((CHAIN_ERRORS + 1))
                return 1
                ;;
            *)
                warn "dependency path is not a regular file: $cur"
                CHAIN_ERRORS=$((CHAIN_ERRORS + 1))
                return 1
                ;;
        esac
    done
}

for p in "${LDD_PATHS[@]}"; do
    vlog "resolving chain: $p"
    collect_chain "$p"
done

[ "$CHAIN_ERRORS" -eq 0 ] || die "could not resolve all dependency symlink chains"

# ---------------------------------------------------------------------------
# Destination paths
# ---------------------------------------------------------------------------
[ "$DEST" = / ] && die "refusing to use / as the destination"
if [ "$DRY_RUN" -eq 0 ]; then
    mkdir -p -- "$DEST" || die "cannot create destination directory: $DEST"
    DEST=$(cd -- "$DEST" && pwd -P) || die "cannot access destination directory: $DEST"
else
    # best effort, do not create anything
    case $DEST in
        /*) ;;
        *) DEST=$PWD/$DEST ;;
    esac
fi
[ "$DEST" = / ] && die "refusing to use / as the destination"

if [ "$LAYOUT" = flat ]; then
    declare -A NAME_FOR=()
    declare -A NAME_USED=()
    for i in "${!ITEM_PATH[@]}"; do
        p=${ITEM_PATH[$i]}
        base=${p##*/}
        [ -n "$base" ] || base=root
        cand=$base
        n=0
        while [ -n "${NAME_USED[$cand]+x}" ]; do
            n=$((n + 1))
            cand="$base.$n"
        done
        NAME_FOR[$p]=$cand
        NAME_USED[$cand]=$p
        if [ "$cand" != "$base" ]; then
            warn "flat name collision for '$base': storing $p as '$cand'"
        fi
    done
fi

copy_regular() { # $1 = container path, $2 = host destination
    local src=$1 dst=$2
    if [ "$DRY_RUN" -eq 1 ]; then
        printf 'copy %s:%s -> %s\n' "$CONTAINER" "$src" "$dst"
        return 0
    fi
    if [ -d "$dst" ]; then
        printf '%s: error: destination is a directory: %s\n' "$PROG" "$dst" >&2
        return 1
    fi
    local tmp="${dst}.copy_dl_tmp.$$"
    if [ -d "$tmp" ] && [ ! -L "$tmp" ]; then
        printf '%s: error: temporary path is a directory: %s\n' "$PROG" "$tmp" >&2
        return 1
    fi
    rm -f -- "$tmp"
    if ! "$ENGINE" cp "$CONTAINER:$src" "$tmp"; then
        rm -f -- "$tmp"
        return 1
    fi
    mv -f -- "$tmp" "$dst"
}

make_link() { # $1 = target text, $2 = host link path
    local target=$1 link=$2
    if [ "$DRY_RUN" -eq 1 ]; then
        printf 'link %s -> %s\n' "$link" "$target"
        return 0
    fi
    rm -f -- "$link"
    ln -s -- "$target" "$link"
}

copied_files=0
copied_links=0

for i in "${!ITEM_PATH[@]}"; do
    p=${ITEM_PATH[$i]}
    k=${ITEM_KIND[$i]}
    if [ "$LAYOUT" = mirror ]; then
        host_path="$DEST$p"
    else
        host_path="$DEST/${NAME_FOR[$p]}"
    fi

    if [ "$DRY_RUN" -eq 0 ]; then
        mkdir -p -- "$(path_dirname "$host_path")" ||
            die "cannot create directory for: $host_path"
    fi

    if [ "$k" = l ]; then
        next=${ITEM_NEXT[$i]}
        if [ -z "${ITEM_SEEN[$next]+x}" ]; then
            die "symlink target was not collected: $p -> $next"
        fi
        if [ "$LAYOUT" = mirror ]; then
            host_next="$DEST$next"
            link_target=$(relpath "$(path_dirname "$host_path")" "$host_next")
        else
            link_target=${NAME_FOR[$next]}
        fi
        vlog "symlink $p -> $next"
        make_link "$link_target" "$host_path" || die "failed to create symlink: $host_path"
        copied_links=$((copied_links + 1))
    else
        vlog "file   $p"
        copy_regular "$p" "$host_path" || die "failed to copy: $p"
        copied_files=$((copied_files + 1))
    fi
done

if [ "$DRY_RUN" -eq 1 ]; then
    info "dry run: $copied_files files and $copied_links symlinks would be copied to $DEST"
else
    info "copied $copied_files files and $copied_links symlinks to $DEST"
fi
