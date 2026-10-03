#!/usr/bin/env bash
set -euo pipefail

export PATH="/usr/sbin:${PATH}"

kernel_release=${KERNEL_RELEASE:-$(uname -r)}
case $(uname -m) in
    x86_64) package_arch=x86_64 ;;
    *)
        printf 'Unsupported architecture: %s\n' "$(uname -m)" >&2
        exit 2
        ;;
esac

cache_dir=${KERNEL_BUILD_CACHE:-"$HOME/.cache/chco-kernel"}
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
patch_dir="$root/patches"
output_dir=${1:-"$root/build/modules/$kernel_release"}

case $kernel_release in
    *-arch*-*)
        pkgrel=${kernel_release##*-}
        arch_release=${kernel_release%-*}
        source_tag="v$arch_release"
        package_version="${arch_release/-arch/.arch}-$pkgrel"
        source_url=https://github.com/archlinux/linux.git
        headers_root=${KERNEL_HEADERS_ROOT:-"$cache_dir/linux-headers-$package_version"}
        headers_dir=${KERNEL_HEADERS:-"$headers_root/usr/lib/modules/$kernel_release/build"}
        headers_package="$cache_dir/linux-headers-$package_version-$package_arch.pkg.tar.zst"
        headers_url=${KERNEL_HEADERS_URL:-"https://archive.archlinux.org/packages/l/linux-headers/${headers_package##*/}"}
        ;;
    *)
        # Debian and Ubuntu name their kernels after their own ABI rather than
        # after the upstream stable version, so the upstream source tag is read
        # from the installed headers once the headers have been validated.
        source_tag=
        source_url=https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git
        headers_dir=${KERNEL_HEADERS:-"/lib/modules/$kernel_release/build"}
        headers_package=
        ;;
esac

for command in git make modinfo patch python3; do
    command -v "$command" >/dev/null || {
        printf 'Required command is unavailable: %s\n' "$command" >&2
        exit 1
    }
done

# Arch's archived headers package supplies the exact generated headers and
# Module.symvers from its package build.  Debian installs equivalent ABI data
# under /lib/modules/$(uname -r)/build, so no source-tree preparation is needed.
if [[ -n $headers_package && ! -s $headers_dir/Module.symvers ]]; then
    for command in curl tar; do
        command -v "$command" >/dev/null || {
            printf 'Required command is unavailable: %s\n' "$command" >&2
            exit 1
        }
    done
    mkdir -p -- "$cache_dir" "$headers_root"
    if [[ ! -s $headers_package ]]; then
        partial="$headers_package.part"
        rm -f -- "$partial"
        curl --fail --location --show-error --output "$partial" "$headers_url"
        mv -- "$partial" "$headers_package"
    fi
    rm -rf -- "$headers_root"
    mkdir -p -- "$headers_root"
    tar --zstd -xf "$headers_package" -C "$headers_root"
fi
if [[ ! -s $headers_dir/Module.symvers ]]; then
    printf 'Kernel headers do not provide %s/Module.symvers\n' "$headers_dir" >&2
    exit 1
fi
# include/config/kernel.release records the release the headers were generated
# for.  'make kernelrelease' reconstructs a release from the Makefile and local
# settings, which does not always preserve a distribution's installed ABI name.
if [[ -s $headers_dir/include/config/kernel.release ]]; then
    prepared_release=$(<"$headers_dir/include/config/kernel.release")
else
    prepared_release=$(make -s -C "$headers_dir" kernelrelease)
fi
if [[ $prepared_release != "$kernel_release" ]]; then
    printf 'Header release %s does not match %s\n' \
        "$prepared_release" "$kernel_release" >&2
    exit 1
fi

# 'make kernelversion' reports VERSION.PATCHLEVEL.SUBLEVEL plus EXTRAVERSION,
# without the distribution suffix that 'make kernelrelease' may append.  This
# is exactly the upstream stable tag the driver must come from.
if [[ -z $source_tag ]]; then
    upstream_version=${KERNEL_UPSTREAM_VERSION:-$(make -s -C "$headers_dir" kernelversion)}
    source_tag="v$upstream_version"
fi
source_dir=${KERNEL_SOURCE:-"$cache_dir/linux-$source_tag"}

if [[ ! -d $source_dir/.git ]]; then
    mkdir -p -- "${source_dir%/*}"
    git clone --quiet --depth 1 --filter=blob:none --single-branch \
        --branch "$source_tag" "$source_url" "$source_dir"
fi
expected=$(git -C "$source_dir" rev-parse "$source_tag^{}")
actual=$(git -C "$source_dir" rev-parse HEAD)
if [[ $actual != "$expected" ]]; then
    printf '%s is at %s, expected %s (%s)\n' \
        "$source_dir" "$actual" "$expected" "$source_tag" >&2
    exit 1
fi

# The archive may contain vmlinux so Kbuild can add module BTF.  Suppress BTF
# only when pahole is absent; BTF is not required to load a module.
vmlinux_backup=
restore_vmlinux() {
    if [[ -n $vmlinux_backup && -e $vmlinux_backup ]]; then
        mv -- "$vmlinux_backup" "$headers_dir/vmlinux"
    fi
}
trap restore_vmlinux EXIT
if [[ -e $headers_dir/vmlinux ]] && ! command -v pahole >/dev/null; then
    vmlinux_backup="$headers_dir/vmlinux.chco-no-btf"
    mv -- "$headers_dir/vmlinux" "$vmlinux_backup"
fi

# The patches are relative to the kernel root, because the series also touches
# Documentation/admin-guide/spkguide.txt.  Patching therefore happens in a tree
# rooted like the kernel, while the out-of-tree module build still needs only
# drivers/accessibility/speakup out of that tree.
#
# Only the files the series names are copied into the patch root.  $source_dir
# is a blobless clone, so copying the whole kernel would fetch every blob in
# it, and $source_dir itself stays pristine so that the tag check above keeps
# meaning something on a later run.
work_dir="$cache_dir/speakup-$source_tag"
rm -rf -- "$work_dir"
shopt -s nullglob
patches=("$patch_dir"/*.patch)
shopt -u nullglob
if (( ${#patches[@]} == 0 )); then
    printf 'No patches were found in %s\n' "$patch_dir" >&2
    exit 1
fi
mapfile -t patched_paths < <(
    sed -n 's|^+++ b/||p' "${patches[@]}" | sort -u
)
for patched_path in "${patched_paths[@]}"; do
    if [[ ! -e $source_dir/$patched_path ]]; then
        printf 'Patched path is absent from %s: %s\n' \
            "$source_dir" "$patched_path" >&2
        exit 1
    fi
    mkdir -p -- "$work_dir/${patched_path%/*}"
    cp -a -- "$source_dir/$patched_path" "$work_dir/$patched_path"
done
# Kbuild needs the whole speakup directory, not only the patched files in it.
cp -a -- "$source_dir/drivers/accessibility/speakup/." \
    "$work_dir/drivers/accessibility/speakup/"
for patch_file in "${patches[@]}"; do
    patch --batch --silent --directory "$work_dir" -p1 <"$patch_file"
done
speakup_dir="$work_dir/drivers/accessibility/speakup"

# Build the patched core and software synthesizer as external modules while
# retaining their standard module names.
python3 - "$speakup_dir/Makefile" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text()
replacements = {
    "obj-$(CONFIG_SPEAKUP_SYNTH_SOFT) += speakup_soft.o":
        "obj-m += speakup_soft.o",
    "obj-$(CONFIG_SPEAKUP) += speakup.o": "obj-m += speakup.o",
}
for old, new in replacements.items():
    if text.count(old) != 1:
        raise SystemExit(f"unexpected upstream Makefile: {old!r} occurs {text.count(old)} times")
    text = text.replace(old, new)
# The distribution config may enable hardware synthesizers too.  They are not
# part of this patched pair and must not become incidental build artifacts.
text = "\n".join(
    line for line in text.splitlines()
    if not line.startswith("obj-$(CONFIG_SPEAKUP_SYNTH_")
) + "\n"
path.write_text(text)
PY

make -s -C "$headers_dir" M="$speakup_dir" clean
make -C "$headers_dir" -j"$(nproc)" M="$speakup_dir" modules
restore_vmlinux
vmlinux_backup=
trap - EXIT

mkdir -p -- "$output_dir"
for module in speakup speakup_soft; do
    cp "$speakup_dir/$module.ko" "$output_dir/"
    actual_name=$(modinfo -F name "$output_dir/$module.ko")
    if [[ $actual_name != "$module" ]]; then
        printf '%s has module name %s, expected %s\n' \
            "$module.ko" "$actual_name" "$module" >&2
        exit 1
    fi
    actual_release=$(modinfo -F vermagic "$output_dir/$module.ko" | awk '{print $1}')
    if [[ $actual_release != "$kernel_release" ]]; then
        printf '%s has vermagic %s, expected %s\n' \
            "$module.ko" "$actual_release" "$kernel_release" >&2
        exit 1
    fi
done
soft_dependencies=$(modinfo -F depends "$output_dir/speakup_soft.ko")
if [[ ,$soft_dependencies, != *,speakup,* ]]; then
    printf 'speakup_soft.ko does not depend on the speakup core\n' >&2
    exit 1
fi

printf 'Built Speakup modules for %s using exact ABI metadata in %s\n' \
    "$kernel_release" "$output_dir"
