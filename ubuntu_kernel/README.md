# Ubuntu kernel build container

Containerised version of the Ubuntu guide
[How to build an Ubuntu Linux kernel](https://ubuntu.com/kernel/docs/how-to/develop-customise/build-kernel/).

The image only provides the build environment (`apt build-dep` for the target
kernel release plus the extra packages from the guide). Kernel sources are
**not** downloaded at image build time:

* `scripts/build_target.sh <src-dir>` bind-mounts an existing source tree at
  `/build/linux`. `<src-dir>` must be the extracted tree itself (e.g.
  `.../linux-7.0.0`, the directory containing `debian/`), not the directory
  that holds the `.dsc`/tarballs.
* `scripts/build_target.sh` without a source directory runs
  `apt source linux-image-unsigned-<kernel-release>` inside the container.

## Files

All scripts and the Dockerfile template live in `scripts/`.

| File | Purpose |
| --- | --- |
| `scripts/Dockerfile.template` | Image template with `__KERNEL_RELEASE__` / `__UBUNTU_RELEASE__` placeholders |
| `scripts/build_image.sh` | Renders the template for a kernel release and builds `ubuntu_kernel_builder:<ubuntu-release>-<kernel-release>` (`--no-build` to only render) |
| `scripts/build_target.sh` | Runs the build (`-i` for an interactive shell first) and copies the `.deb` files back to the host |
| `scripts/build_in_container.sh` | In-container build logic, baked into the image as `/usr/local/bin/ubuntu-kernel-build.sh` |

## Quick start

```bash
# 1. Render ./Dockerfile and build the image in one go
#    -> ubuntu_kernel_builder:noble-6.8.0-45-generic
./scripts/build_image.sh 6.8.0-45-generic

# ... or only render it, e.g. to inspect it first
./scripts/build_image.sh 6.8.0-45-generic --no-build

# 2a. Build an existing source tree (mounted at /build/linux)
./scripts/build_target.sh ~/src/linux -k 6.8.0-45-generic

# 2b. Or let the container fetch the source with apt source
./scripts/build_target.sh -k 6.8.0-45-generic

# 2c. Same, but stop in a shell inside the container first
./scripts/build_target.sh ~/src/linux -k 6.8.0-45-generic -i

# 2d. Build only one of the flavours listed in debian.<kernel>/rules.d/<arch>.mk
./scripts/build_target.sh ~/src/linux -k 7.0.0-34-generic -l cxltest
```

The image tag combines the Ubuntu release and the kernel release from the
`scripts/build_image.sh` arguments:
`ubuntu_kernel_builder:<ubuntu-release>-<kernel-release>`. `scripts/build_target.sh`
looks up the matching local image automatically; pass `-r noble` if several
Ubuntu releases carry the same kernel release.

The `.deb` files are collected in `./debs/<kernel-release>/` by default
(`-o/--output` to change it).

## Interactive shell (`-i`)

By default `scripts/build_target.sh` builds straight away. With `-i/--interactive`
(and a terminal) it stops in a shell inside the container, in the prepared
source tree, before anything is built:

* the mounted tree is already chown'ed to `HOST_UID:HOST_GID` (or the source
  is already fetched in `apt source` mode) and `debian/scripts` are
  executable, so `fakeroot debian/rules editconfigs` works right away;
* this is where config, flavour and changelog changes are made (see below);
* leaving the shell (`exit` / Ctrl-D) runs
  `fakeroot debian/rules clean && fakeroot debian/rules binary`, i.e. the
  regular build; `exit 1` aborts without building.

`-i` without a TTY (e.g. stdin redirected) is an error rather than a silently
skipped shell.

`debian/rules clean` runs *after* the shell, so editing
`debian.master/rules.d/<arch>.mk` or the changelog there also regenerates
`debian/control` correctly.

## Selecting the flavour(s) to build

By default every flavour listed in `debian.<kernel>/rules.d/<arch>.mk`
(`flavours = ...`) is built, which can be slow when the tree carries several
(e.g. `generic` and a custom one). `-l/--flavours` overrides that list for a
single build without touching the source tree:

```bash
./scripts/build_target.sh ~/src/linux -k 7.0.0-34-generic -l cxltest
./scripts/build_target.sh ~/src/linux -k 7.0.0-34-generic -l "generic cxltest"   # or generic,cxltest
```

It is forwarded to the container as `BUILD_FLAVOURS` and applied as
`fakeroot debian/rules binary flavours=<list>`. Make command line variables win
over the ones assigned in the makefiles, so this is equivalent to temporarily
editing `flavours` in `rules.d/<arch>.mk` (which is the alternative if the image
predates this option). Note that environment variables can *not* be used for
this -- a `flavours = ...` assignment in the makefile overrides them.

Only the listed flavours are compiled and packaged; the packages declared in
`debian/control` for the other flavours simply are not built (all `dh_*` calls
are scoped with `-p<package>`, so this is fine for `debian/rules binary`).

## Changing the config / the kernel name

The `.config` is generated from `debian.master/config/annotations` on every
build (`debian/scripts/misc/annotations --export`), so a `.config` dropped into
the source tree is ignored:

* annotate options in `debian.master/config/annotations`, either by appending
  `CONFIG_FOO policy<{'amd64': 'y'}>` lines (later lines override earlier ones)
  or with
  `debian/scripts/misc/annotations --arch amd64 --flavour generic --update <file>`;
* `fakeroot debian/rules editconfigs` also works but walks every arch/flavour
  of the `# FLAVOUR:` header and aborts while importing the configs of arches
  whose cross toolchain is not installed. Trim the header to the arch you
  build, or use `--update` instead.

The installed name is `<version>-<abi>-<flavour>` (e.g. `7.0.0-34-generic`):

| What | Where |
| --- | --- |
| ABI / release | first line of `debian.master/changelog`, e.g. `linux (7.0.0-999.1) resolute; urgency=medium` |
| flavour | `debian.master/rules.d/amd64.mk` (`flavours = mykernel`), `debian.master/control.d/vars.mykernel` (renamed from `vars.generic`, adjust `arch`/`depends`), `# FLAVOUR: amd64-mykernel` in `debian.master/config/annotations` |

Renaming the source package (`linux (...)`) alone does not rename
`linux-image-unsigned-*`: those prefixes are hardcoded in
`debian/rules.d/0-common-vars.mk` and the `control.d` stubs. `CONFIG_LOCALVERSION`
has no effect either, because `debian/rules` passes `KERNELRELEASE` explicitly
and the kernel Makefile then takes the `echo $(KERNELRELEASE)` path instead of
`scripts/setlocalversion`.

## Choosing the Ubuntu release

`scripts/build_image.sh` infers the base image from the kernel version:

| Kernel | Ubuntu |
| --- | --- |
| 6.8 | noble (24.04 LTS) |
| 6.11 | oracular (24.10) |
| 6.14 | plucky (25.04) |
| 6.17 | questing (25.10) |
| 7.0 | resolute (26.04 LTS) |

For HWE kernels or anything not in the table, pass the archive explicitly,
e.g. a 6.17 kernel installed on 24.04:

```bash
./scripts/build_image.sh 6.17.0-14-generic -r noble   # -> ubuntu_kernel_builder:noble-6.17.0-14-generic
```

## Notes

* The image installs `apt build-dep` for the target kernel plus only
  `build-essential` and the four packages from the guide
  (`fakeroot llvm libncurses-dev dwarves`). Everything else is already covered
  by the kernel's own `Build-Depends`.
* The in-container steps live in `scripts/build_in_container.sh` and are
  `COPY`ed into the image as `/usr/local/bin/ubuntu-kernel-build.sh`, so
  `scripts/build_target.sh` only passes mounts and environment variables. Changing
  that script requires re-running `scripts/build_image.sh` (the apt layers
  stay cached). If the Dockerfile is rendered outside this directory, a copy
  of the script is staged into the build context for the build and removed
  afterwards.
* In `apt source` mode the container unpacks the tree into `/build`
  (`/build/linux-<version>`) and creates a symlink `/build/linux` to it, so
  the layout is the same as with a bind-mounted source directory. Note that
  `apt source` uses the source version currently in the archive, which can be
  newer than the ABI in the requested kernel release.
* Without `-i`/`--interactive` the build starts immediately; see "Interactive
  shell" above for the shell workflow.
* `-l/--flavours` (see "Selecting the flavour(s) to build") requires an image
  built from this version of `scripts/build_in_container.sh`, since that is where
  `BUILD_FLAVOURS` is turned into the `flavours=` make argument -- re-run
  `scripts/build_image.sh` once after updating this directory.
* With a mounted source tree the container starts as root, changes the owner
  of `/build/linux` (only if some entries do not match) and `/output` to
  `HOST_UID:HOST_GID`, then re-executes the build with `setpriv` as that user.
  This also fixes trees that were created by a previous root container, so the
  source tree and the `.deb` files end up owned by the caller. Use `--root` to
  skip the ownership fix and build as root. With a rootless engine (e.g.
  rootless podman) use `--root` as well, since uid mapping makes the chown
  meaningless.
* In `apt source` mode the build runs as root inside the container (it needs
  to install packages and fetch the source); `/output` is chown'ed to
  `HOST_UID:HOST_GID` after the `.deb` files are copied.
* `do_linux_main_modules_depends=false` is exported, as recommended for
  development builds (zfs / v4l2loopback modules are skipped).
* To avoid clashing with Canonical's packages, bump the ABI in the changelog
  (`debian.master/changelog` for the generic kernel) before building, e.g.
  `linux (6.8.0-999.48) noble; urgency=medium`.
* `CONCURRENCY_LEVEL` / `DEB_BUILD_OPTIONS=parallel=N` are set from `-j`
  (default: `nproc`).
* Extra options for `docker build` can be passed to `scripts/build_image.sh`
  after `--` (e.g. `-- --pull --progress=plain`); set `DOCKER=podman` to use
  another engine.
