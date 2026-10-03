# Speakup Unicode patches

Speakup is the Linux kernel's screen reader for text consoles. This repository
contains a twelve-patch series that lets it preserve and speak Unicode scalar
values throughout its speech and screen-review paths, including four-byte code
points. Coverage includes Basic Multilingual Plane Chinese and supplementary
characters such as U+20000.

`patches/` holds the patches in `git format-patch` form. Apply them in filename
order; each patch expects the patches before it. Every patch builds on its own,
so `git bisect` over the series remains meaningful.

## Warning

- If you are using a hardware synthesizer, these patches might add spoken output for smart quotes and other symbols that were not previously voiced.
- Verify the validity of the commands written here for your particular system, before executing them.
- The author assumes no responsibility for the actions you take with the contents of this repository.

## Patch series

Stage A fixes UTF-8 decoding without changing any types:

1. `advance synth_writeu by the consumed byte count` stops re-examining the
   continuation bytes of every multibyte sequence.
2. `reject malformed UTF-8 in synth_utf8_get` rejects overlong forms,
   surrogate code points, values above U+10FFFF, and sequences longer than
   four bytes.

Stage B carries 32-bit code points from the virtual terminal through the
synthesizer buffer to `/dev/synthu` and `/dev/softsynthu`:

3. `carry Unicode scalar values through the speech path` widens every
   variable, array, and signature that holds a code point from `u16` to `u32`.
4. `stop discarding code points above U+FFFF` removes the two checks that
   discarded supplementary-plane characters.
5. `encode four-byte UTF-8 for the Unicode devices` adds four-byte encoding to
   `/dev/softsynthu` and `spk_ttyio_out_unicode`.

Stage C makes screen-review commands read and speak the same code points:

6. `read review characters from the console Unicode screen buffer` replaces
   glyph-index back-translation with `screen_glyph_unicode`.
7. `skip the filler cell of a double-width character` keeps review on a
   double-width Chinese character instead of the zero-width filler cell stored
   beside it by the console.

Stage D names and classifies characters that a synthesizer otherwise renders
as silence:

8. `describe code points above Latin-1 with an extended table` adds the table,
   accessors, and macro rewrite. It has no default entries, so this patch alone
   changes no spoken output.
9. `accept A_PUNC_WDLM as a chartab keyword` names the class that both
   announces a mark and ends a word.
10. `expose the extended character table through sysfs` adds
    `/sys/accessibility/speakup/i18n/ext_characters` and `ext_chartab`, allowing
    any code point to be named without another kernel change.
11. `fold a code point onto a pronounceable equivalent` adds a fold target and
    applies it everywhere a character reaches the synthesizer. It has no
    default fold target, so this patch alone changes no spoken output.
12. `name Chinese and fullwidth punctuation by default` adds 76 table entries
    and folds the ten fullwidth digits onto ASCII digits.

Patches 10 and 12 also update `Documentation/admin-guide/spkguide.txt`. Patch
10 adds section 12.1 for the two sysfs files; patch 12 rewrites section 14.3,
which previously said Speakup supports Western European languages only.

All patch paths are relative to the kernel root, as produced by
`git format-patch`, because the series touches both
`drivers/accessibility/speakup` and `Documentation/admin-guide/spkguide.txt`.
To apply the series to a kernel checkout manually:

```sh
git am /path/to/su/patches/*.patch
```

## Project status and tested systems

This is an experimental patch series, not an upstream or distribution-supported
Speakup release. It has been built and tested on these x86-64 systems:

- Arch Linux `7.1.8-arch1-3`.
- Debian sid (unstable) `7.2.7+deb14-amd64`, package version `7.2.7-1`.

Other kernel releases and distribution patch sets are untested. A successful
build does not by itself establish that the modules are safe to load on an
untested kernel.

Loading these modules requires the distribution Speakup core to be modular
(`CONFIG_SPEAKUP=m`). If `CONFIG_SPEAKUP=y`, Speakup is built into the kernel
and cannot be unloaded or replaced without booting a kernel built with the
patches. Check the running kernel configuration with one of:

```sh
grep '^CONFIG_SPEAKUP=' "/boot/config-$(uname -r)"
zgrep '^CONFIG_SPEAKUP=' /proc/config.gz
```

The modules are unsigned. A kernel enforcing Secure Boot module signatures
will refuse to load them unless the user signs them with a key trusted by that
system or disables signature enforcement. Signing and key enrollment are
distribution-specific.

## Build patched modules

`build.sh` builds patched modules for the running x86-64 kernel:

```sh
./build.sh
```

The resulting modules are written to:

```text
build/modules/$(uname -r)/speakup.ko
build/modules/$(uname -r)/speakup_soft.ko
```

An alternative output directory can be passed as the first argument:

```sh
./build.sh /tmp/speakup-modules
```

The modules retain the standard `speakup` and `speakup_soft` names. The builder
writes them only to the output directory; it does not install them or replace
the stock modules on disk.

The builder requires Bash, Git, GNU make, `patch`, Python 3, `modinfo`, the
running kernel's exact ABI metadata, and network access on the first run. On
Arch Linux it downloads the matching archived headers package and source tag.
On Debian and Ubuntu it uses `/lib/modules/$(uname -r)/build` and derives the
upstream stable source tag from those headers. Downloaded source and headers
are cached in `~/.cache/chco-kernel` by default.

Useful overrides are:

- `KERNEL_RELEASE`: kernel release to build for.
- `KERNEL_HEADERS`: prepared kernel headers directory.
- `KERNEL_HEADERS_ROOT`: extracted Arch headers package root.
- `KERNEL_HEADERS_URL`: alternate Arch headers package URL.
- `KERNEL_SOURCE`: existing checkout of the expected source tag.
- `KERNEL_UPSTREAM_VERSION`: upstream version for Debian/Ubuntu-style kernels.
- `KERNEL_BUILD_CACHE`: cache directory.

The source checkout is kept pristine. The script copies only the files needed
by the patch series and the Speakup Kbuild into a temporary kernel-shaped tree,
applies the patches there, and performs an out-of-tree module build against
the exact installed ABI metadata.

## Load the modules for testing

Do this only from a recoverable session. Unloading Speakup interrupts speech,
and a failed replacement can leave the console without speech until the stock
modules are loaded again or the system is rebooted. Do not configure the
experimental modules to load at boot until they have worked interactively.

First unload the stock software synthesizer and core. Any other synthesizer
module using the stock core must also be unloaded:

```sh
sudo modprobe -r speakup_soft speakup
```

Then load the patched core before its software synthesizer, using the output
directory printed by `build.sh`:

```sh
sudo insmod "build/modules/$(uname -r)/speakup.ko"
sudo insmod "build/modules/$(uname -r)/speakup_soft.ko"
```

The builder does not install the patched modules or replace the stock modules
on disk. Do not load the stock and patched Speakup cores at the same time; they
compete for the same subsystem resources. This build does not provide patched
hardware-synthesizer modules, and stock synthesizer modules are not supported
with the patched core because the series changes exported Speakup interfaces.

To return to the stock software synthesizer:

```sh
sudo rmmod speakup_soft speakup
sudo modprobe speakup_soft
```

A reboot also returns to the stock modules unless the experimental modules
have been copied into the system module tree or added to boot configuration.

## Permanently install the modules

Only install the modules permanently after testing them successfully as
described above. Modules are tied to one exact kernel release, so repeat the
build and installation after every kernel update. For the running kernel,
install them in an `updates/` subdirectory rather than overwriting files owned
by the distribution package:

```sh
release=$(uname -r)
sudo install -d "/lib/modules/$release/updates/speakup-unicode"
sudo install -m 0644 "build/modules/$release/speakup.ko" \
  "/lib/modules/$release/updates/speakup-unicode/speakup.ko"
sudo install -m 0644 "build/modules/$release/speakup_soft.ko" \
  "/lib/modules/$release/updates/speakup-unicode/speakup_soft.ko"
sudo depmod -a "$release"
```

Adjust the two source paths if `build.sh` was given another output directory.
Confirm that module lookup selects both installed copies before rebooting:

```sh
modinfo -k "$release" -n speakup
modinfo -k "$release" -n speakup_soft
```

Both commands must print paths below
`/lib/modules/$release/updates/speakup-unicode/`. If either command points to a
distribution module, do not reboot into this setup; that system's depmod search
configuration is not giving `updates/` precedence.

Do not blacklist `speakup` or `speakup_soft`. A modprobe blacklist identifies a
module by its internal name, not by the path or package that supplied its
`.ko` file. The patched and distribution modules deliberately have the same
names, so there is no blacklist rule that rejects only the distribution
copies. The `updates/` directory and the dependency index generated by
`depmod` select the patched copies while leaving the package-owned files
untouched.

Keep any existing boot configuration that loaded the distribution
`speakup_soft` module; it will now resolve to the installed patched pair. If no
such configuration exists, enable the software synthesizer at boot with:

```sh
printf '%s\n' speakup_soft | sudo tee /etc/modules-load.d/speakup-unicode.conf
```

If Speakup is included in the initramfs, rebuild that image so it does not
retain the distribution modules. Use the command for the installed
distribution:

```sh
# Arch Linux
sudo mkinitcpio -P

# Debian or Ubuntu
sudo update-initramfs -u -k "$release"
```

The unsigned-module and Secure Boot restrictions described above still apply.
Reboot to replace any modules that are already loaded.

To uninstall both patched modules, use the running kernel release and remove
the boot configuration only if it was created above:

```sh
release=$(uname -r)
sudo rm -f /etc/modules-load.d/speakup-unicode.conf
sudo rm -f "/lib/modules/$release/updates/speakup-unicode/speakup.ko"
sudo rm -f "/lib/modules/$release/updates/speakup-unicode/speakup_soft.ko"
sudo rmdir "/lib/modules/$release/updates/speakup-unicode"
sudo depmod -a "$release"
```

Rebuild the initramfs with the applicable command above, then confirm that
`modinfo -k "$release" -n speakup` and `modinfo -k "$release" -n
speakup_soft` resolve to the distribution paths. Reboot to replace the loaded
modules. No distribution files need to be restored.

When reporting a problem, include the complete build or module-loading error,
`uname -a`, the distribution and kernel package version, the values of
`CONFIG_SPEAKUP` and `CONFIG_MODVERSIONS`, relevant `modinfo` output, and
whether Secure Boot is enabled.

## Mainline compatibility

The series currently targets the stable kernel source corresponding to the
installed distribution kernel. Mainline replaced every `(u_short *)` cast in
`main.c` with `(u16 *)`. Those casts occur as hunk context in seven patches, so
the series must be rebased before it can be applied to current mainline.
