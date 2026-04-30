# cef-vaapi

Arch Linux [CEF](https://chromiumembedded.github.io/cef) package rebuilt with VAAPI hardware video decode enabled, while preserving proprietary codec support (H.264, AAC, HEVC).

## What this is

The official Arch [`cef`](https://archlinux.org/packages/extra/x86_64/cef/) package builds CEF with `use_vaapi=false`. This package is identical to Arch's except for the smallest possible delta:

- `use_vaapi=true` — enables AMD VCN / Intel VAAPI hardware video decode
- Package rename + metadata (`provides`, `conflicts`, `optdepends`)
- Explicit `libva` runtime dependency + driver notes
- Build-time guardrails that fail if required flags drift

Everything else proprietary codecs, bundled ffmpeg, PipeWire, PulseAudio, build flags, patches matches Arch's `cef` exactly.

## How to build

```bash
git clone https://aur.archlinux.org/cef-vaapi.git
cd cef-vaapi
makepkg -s
```

This will take several hours.

To verify VAAPI was compiled in after building:

```bash
strings /usr/lib/cef/libcef.so | grep -E 'vaCreateContext|VaapiVideoDecoder::|libva\.so'
```

## How it tracks Arch

When Arch updates its official `cef` package:

1. Run `scripts/update-from-arch-cef.sh` to re-fetch Arch's packaging and reapply the delta
2. Review the diff
3. Update `.SRCINFO` with `makepkg --printsrcinfo > .SRCINFO`
4. Commit and push

A GitHub Actions workflow automates this periodically.

## AUR package identity

| Field | Value |
|-------|-------|
| Package | `cef-vaapi` |
| Provides | `cef=$pkgver` |
| Conflicts | `cef` |
| License | `BSD-3-Clause` (CEF upstream) |
| Repository license | MIT (scripts, docs, workflows) |

## License

- Repository scripts, documentation, and workflow files: MIT — see `LICENSE`
- Upstream Arch packaging metadata copied from Arch Linux: ISC — see `LICENSE.ARCH-ISC`
- CEF framework itself: BSD-3-Clause — declared in PKGBUILD `license=('BSD-3-Clause')`
