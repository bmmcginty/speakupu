# Speakup Unicode patches

This repository contains a twelve-patch series that lets Speakup carry full
Unicode, including four-byte code points. Coverage includes Basic Multilingual
Plane Chinese and supplementary characters such as U+20000.

`patches/` holds the patches in `git format-patch` form. Apply them in filename
order; each patch expects the patches before it. Every patch builds on its own,
so `git bisect` over the series remains meaningful.

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

## Mainline compatibility

The series currently targets the stable kernel source corresponding to the
installed distribution kernel. Mainline replaced every `(u_short *)` cast in
`main.c` with `(u16 *)`. Those casts occur as hunk context in seven patches, so
the series must be rebased before it can be applied to current mainline.
