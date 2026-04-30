#!/usr/bin/env bash
set -euo pipefail

ARCH_CEF_REPO="https://gitlab.archlinux.org/archlinux/packaging/packages/cef.git"
CACHE_DIR="${CEF_ARCH_CACHE:-/tmp/cef-vaapi-arch-cef}"
OUTPUT_DIR="$(pwd)"

usage() {
  cat <<EOF
Usage: $0 [--output-dir DIR]

Fetch Arch's official cef packaging and generate cef-vaapi packaging files.
EOF
}

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir)
      [[ $# -ge 2 ]] || die "--output-dir requires a value"
      OUTPUT_DIR="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

require_cmd git
require_cmd python3
require_cmd makepkg

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"

log "Fetching upstream Arch CEF packaging into $CACHE_DIR"
if [[ -d "$CACHE_DIR/.git" ]]; then
  git -C "$CACHE_DIR" fetch --depth 1 origin main
  git -C "$CACHE_DIR" reset --hard FETCH_HEAD >/dev/null
else
  rm -rf "$CACHE_DIR"
  git clone --depth 1 "$ARCH_CEF_REPO" "$CACHE_DIR"
fi

[[ -f "$CACHE_DIR/PKGBUILD" ]] || die "Upstream PKGBUILD not found in $CACHE_DIR"

log "Copying local assets"
find "$CACHE_DIR" -maxdepth 1 -type f -name '*.patch' -exec cp -f -t "$OUTPUT_DIR" {} +
cp -f "$CACHE_DIR/FindCEF.cmake" "$OUTPUT_DIR/"
cp -f "$CACHE_DIR/REUSE.toml" "$OUTPUT_DIR/"
# Preserve Arch's ISC packaging license alongside repo MIT
cp -f "$CACHE_DIR/LICENSE" "$OUTPUT_DIR/LICENSE.CEF-BSD3"
if [[ -d "$CACHE_DIR/LICENSES" ]]; then
  rm -rf "$OUTPUT_DIR/LICENSES"
  cp -a "$CACHE_DIR/LICENSES" "$OUTPUT_DIR/LICENSES"
fi
[[ -f "$OUTPUT_DIR/FindCEF.cmake" ]] || die "Missing copied asset: FindCEF.cmake"

log "Transforming PKGBUILD"
python3 - "$CACHE_DIR/PKGBUILD" "$OUTPUT_DIR/PKGBUILD" <<'PYEOF'
from pathlib import Path
import re
import sys

src = Path(sys.argv[1])
dst = Path(sys.argv[2])
text = src.read_text()


def fail(msg):
    raise SystemExit(f"ERROR: {msg}")


def replace_once(haystack, old, new, label):
    count = haystack.count(old)
    if count != 1:
        fail(f"expected exactly one {label}, found {count}")
    return haystack.replace(old, new, 1)

text = replace_once(text, "pkgname=cef", "pkgname=cef-vaapi", "pkgname assignment")

pkgdesc_re = re.compile(r'^(pkgdesc=)(["\'])(.*?)(\2)$', re.MULTILINE)
match = pkgdesc_re.search(text)
if not match:
    fail("pkgdesc assignment not found")
quote = match.group(2)
desc = match.group(3)
if "VAAPI" not in desc:
    desc = f"{desc} (VAAPI-enabled variant)"
text = text[:match.start()] + f"pkgdesc={quote}{desc}{quote}" + text[match.end():]

# Add provides/conflicts immediately after pkgdesc.
if "\nprovides=" not in text:
    text = re.sub(
        r'^(pkgdesc=.*)$',
        lambda m: m.group(1) + '\nprovides=("cef=$pkgver")  # provides="cef=$pkgver"\nconflicts=(\'cef\')  # conflicts=\'cef\'',
        text,
        count=1,
        flags=re.MULTILINE,
    )
else:
    fail("upstream unexpectedly already has provides")

# Keep the CEF git checkout directory named cef even though pkgname is cef-vaapi.
text = text.replace(
    '"$pkgname::git+https://github.com/chromiumembedded/cef.git',
    '"cef::git+https://github.com/chromiumembedded/cef.git',
)
text = text.replace(
    '"cef-vaapi::git+https://github.com/chromiumembedded/cef.git',
    '"cef::git+https://github.com/chromiumembedded/cef.git',
)

# Add libva to depends only, preserving the existing array shape.
dep_re = re.compile(r'(?ms)^depends=\(\n(?P<body>.*?)^\)')
match = dep_re.search(text)
if not match:
    fail("depends array not found")
body = match.group("body")
if re.search(r"^[ \t]*'libva'[ \t]*$", body, re.MULTILINE) is None:
    body = body.rstrip("\n") + "\n  'libva'\n"
    text = text[:match.start("body")] + body + text[match.end("body"):]

# Add optdepends after depends, as requested.
if "\noptdepends=" not in text:
    match = dep_re.search(text)
    if not match:
        fail("depends array not found after libva insertion")
    optdepends = """\noptdepends=(
  'libva-mesa-driver: VAAPI driver for AMD GPUs'
  'intel-media-driver: VAAPI driver for modern Intel GPUs'
  'libva-utils: VAAPI diagnostics such as vainfo'
)
"""
    text = text[:match.end()] + optdepends + text[match.end():]
else:
    fail("upstream unexpectedly already has optdepends")

if "'use_vaapi=false'" not in text:
    fail("'use_vaapi=false' flag not found")
text = replace_once(text, "'use_vaapi=false'", "'use_vaapi=true'", "use_vaapi flag")

required_flags = [
    "'ffmpeg_branding=\"Chrome\"'",
    "'proprietary_codecs=true'",
    "'rtc_use_pipewire=true'",
    "'link_pulseaudio=true'",
    "'use_vaapi=true'",
]
for flag in required_flags:
    if flag not in text:
        fail(f"required GN flag missing after transform: {flag}")

if re.search(r'(?m)^[ \t]*\[ffmpeg\]=', text):
    fail("_system_libs[ffmpeg] is enabled; it must remain commented or absent")
if "replaces=" in text:
    fail("replaces must not be set")
if "cef-vaapi::git+https://github.com/chromiumembedded/cef.git" in text:
    fail("CEF source alias must not be cef-vaapi::")
if "cef::git+https://github.com/chromiumembedded/cef.git" not in text:
    fail("CEF source alias cef:: not found")

guardrails = r'''
_validate_cef_vaapi_invariants() {
  local _pkgbuild="${BASH_SOURCE[0]}"
  local _required_flags=(
    'ffmpeg_branding="Chrome"'
    'proprietary_codecs=true'
    'rtc_use_pipewire=true'
    'link_pulseaudio=true'
    'use_vaapi=true'
  )
  local _flag _actual _flag_ok
  for _flag in "${_required_flags[@]}"; do
    _flag_ok=0
    for _actual in "${_flags[@]}"; do
      if [[ "$_actual" == "$_flag" ]]; then
        _flag_ok=1
        break
      fi
    done
    if (( ! _flag_ok )); then
      echo "ERROR: required GN flag missing or changed: ${_flag}" >&2
      exit 1
    fi
  done

  if grep -Eq '^[[:space:]]*\[ffmpeg\]=' "$_pkgbuild"; then
    echo "ERROR: _system_libs[ffmpeg] must stay commented or absent" >&2
    exit 1
  fi

  local _source_ok=0 _s
  for _s in "${source[@]}"; do
    if [[ "$_s" == cef::git+https://github.com/chromiumembedded/cef.git* ]]; then
      _source_ok=1
      break
    fi
  done
  if (( ! _source_ok )); then
    echo "ERROR: source must use cef::git+https://github.com/chromiumembedded/cef.git" >&2
    exit 1
  fi

  local _provides_ok=0 _p
  for _p in "${provides[@]}"; do
    if [[ "$_p" == cef=* ]]; then
      _provides_ok=1
      break
    fi
  done
  if (( ! _provides_ok )); then
    echo "ERROR: provides must include cef=\$pkgver" >&2
    exit 1
  fi

  local _conflicts_ok=0 _c
  for _c in "${conflicts[@]}"; do
    if [[ "$_c" == cef ]]; then
      _conflicts_ok=1
      break
    fi
  done
  if (( ! _conflicts_ok )); then
    echo "ERROR: conflicts must include cef" >&2
    exit 1
  fi

  if declare -p replaces >/dev/null 2>&1; then
    echo "ERROR: replaces must not be set" >&2
    exit 1
  fi

  local _libva_ok=0 _d
  for _d in "${depends[@]}"; do
    if [[ "$_d" == libva ]]; then
      _libva_ok=1
      break
    fi
  done
  if (( ! _libva_ok )); then
    echo "ERROR: depends must include libva" >&2
    exit 1
  fi
}
'''

if "_validate_cef_vaapi_invariants" in text:
    fail("guardrails function already exists unexpectedly")
text = text.replace("\nprepare() {", guardrails + "\nprepare() {", 1)

export_marker = '  export GN_DEFINES="${_flags[*]}"\n'
if export_marker not in text:
    fail("GN_DEFINES export not found")
text = text.replace(export_marker, '  _validate_cef_vaapi_invariants\n\n' + export_marker, 1)

dst.write_text(text)
PYEOF

log "Validating PKGBUILD syntax"
bash -n "$OUTPUT_DIR/PKGBUILD"

log "Regenerating .SRCINFO"
(
  cd "$OUTPUT_DIR"
  makepkg --printsrcinfo > .SRCINFO
)

log "Running final checks"
PKG="$OUTPUT_DIR/PKGBUILD"
SRC="$OUTPUT_DIR/.SRCINFO"
grep -q 'pkgname=cef-vaapi' "$PKG" || die "pkgname check failed"
grep -q 'use_vaapi=true' "$PKG" || die "VAAPI flag check failed"
! grep -q 'use_vaapi=false' "$PKG" || die "use_vaapi=false remains"
grep -q 'ffmpeg_branding="Chrome"' "$PKG" || die "ffmpeg_branding check failed"
grep -q 'proprietary_codecs=true' "$PKG" || die "proprietary_codecs check failed"
grep -q 'rtc_use_pipewire=true' "$PKG" || die "rtc_use_pipewire check failed"
grep -q 'link_pulseaudio=true' "$PKG" || die "link_pulseaudio check failed"
grep -q "provides=(\"cef=\$pkgver\")" "$PKG" || die "provides check failed"
grep -q "conflicts=('cef')" "$PKG" || die "conflicts check failed"
! grep -q 'replaces=' "$PKG" || die "replaces must not be set"
grep -q "'libva'" "$PKG" || die "libva depends check failed"
grep -q 'cef::git+https://github.com/chromiumembedded/cef.git' "$PKG" || die "source alias check failed"
! grep -q 'cef-vaapi::git+https://github.com/chromiumembedded/cef.git' "$PKG" || die "bad source alias found"
! grep -Eq '^[[:space:]]*\[ffmpeg\]=' "$PKG" || die "_system_libs[ffmpeg] is enabled"
grep -q '_validate_cef_vaapi_invariants' "$PKG" || die "guardrails missing"
grep -q 'pkgbase = cef-vaapi' "$SRC" || die ".SRCINFO pkgbase check failed"

log "Update complete: $OUTPUT_DIR"
log "Created/updated PKGBUILD, .SRCINFO, patches, FindCEF.cmake, LICENSE.CEF-BSD3, REUSE.toml, LICENSES/"
