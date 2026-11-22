#!/usr/bin/env bash
set -euo pipefail

ARCH_CEF_REPO="https://gitlab.archlinux.org/archlinux/packaging/packages/cef.git"
CACHE_DIR="${CEF_ARCH_CACHE:-/tmp/cef-vaapi-arch-cef}"
OUTPUT_DIR="$(pwd)"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

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

# Pin to the same stable packaging tag selected by the workflow. Standalone
# invocations resolve extra stable too, never packaging main / extra-testing.
if [[ -z ${CEF_ARCH_REF:-} ]]; then
  CEF_ARCH_REF=$(python3 "$SCRIPT_DIR/arch-cef-stable.py" | sed -n 's/^ref=//p')
fi
[[ "$CEF_ARCH_REF" =~ ^[0-9][0-9A-Za-z.+:_-]*$ ]] || die "Invalid stable packaging tag"
log "Fetching upstream Arch CEF packaging tag $CEF_ARCH_REF into $CACHE_DIR"
if [[ ! -d "$CACHE_DIR/.git" ]]; then
  mkdir -p "$CACHE_DIR"
  git -C "$CACHE_DIR" init
  git -C "$CACHE_DIR" remote add origin "$ARCH_CEF_REPO"
fi
git -C "$CACHE_DIR" fetch --depth 1 origin "refs/tags/$CEF_ARCH_REF"
git -C "$CACHE_DIR" reset --hard FETCH_HEAD >/dev/null

[[ -f "$CACHE_DIR/PKGBUILD" ]] || die "Upstream PKGBUILD not found in $CACHE_DIR"

log "Copying local assets"
find "$CACHE_DIR" -maxdepth 1 -type f \( -name '*.patch' -o -name '*.diff' \) -exec cp -f -t "$OUTPUT_DIR" {} +
cp -f "$CACHE_DIR/FindCEF.cmake" "$OUTPUT_DIR/"
cp -f "$CACHE_DIR/REUSE.toml" "$OUTPUT_DIR/"
# Preserve Arch's ISC packaging license alongside repo MIT
cp -f "$CACHE_DIR/LICENSE" "$OUTPUT_DIR/LICENSE.ARCH-ISC"
if [[ -d "$CACHE_DIR/LICENSES" ]]; then
  rm -rf "$OUTPUT_DIR/LICENSES"
  cp -a "$CACHE_DIR/LICENSES" "$OUTPUT_DIR/LICENSES"
fi
[[ -f "$OUTPUT_DIR/FindCEF.cmake" ]] || die "Missing copied asset: FindCEF.cmake"

log "Transforming PKGBUILD"
python3 - "$CACHE_DIR/PKGBUILD" "$OUTPUT_DIR/PKGBUILD" "$CACHE_DIR/local-patches" <<'PYEOF'
from pathlib import Path
import hashlib
import re
import sys

src = Path(sys.argv[1])
dst = Path(sys.argv[2])
out_dir = dst.parent
local_patch_list = Path(sys.argv[3])
cache_dir = src.parent
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

# Drop any upstream replacement policy. cef-vaapi should provide/conflict with cef,
# but it must not replace Arch packages automatically.
text = re.sub(r'(?ms)^replaces=\(.*?^\)\n*', '', text)
text = re.sub(r'(?m)^replaces=[^\n]*\n*', '', text)

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
text = replace_once(text, "  rm third_party/depot_tools/ninja", "  rm -f third_party/depot_tools/ninja", "depot_tools ninja removal")

# cef-vaapi's own Chromium patches. Arch's PKGBUILD does not know about them,
# so each sync must add them back or they silently drop out of the build.
local_patches = {
    "chromium-154-fallback-linux-ui-portal-color-scheme.patch": (
        "  # use_gtk/use_qt are disabled, so FallbackLinuxUi receives the portal color\n"
        "  # scheme; make it reach web content (prefers-color-scheme), crbug.com/536445418\n"
    ),
}
source_re = re.compile(r'(?ms)^source=\(\n(?P<body>.*?)^\)')
sums_re = re.compile(r'(?ms)^sha256sums=\((?P<body>.*?)\)')


def source_entries(haystack):
    match = source_re.search(haystack)
    if not match:
        fail("source array not found")
    return [line.strip() for line in match.group("body").splitlines()
            if line.strip() and not line.strip().startswith("#")]


def sum_entries(haystack):
    match = sums_re.search(haystack)
    if not match:
        fail("sha256sums array not found")
    return re.findall(r"'([0-9a-f]{64}|SKIP)'", match.group("body"))


if len(source_entries(text)) != len(sum_entries(text)):
    fail("upstream source and sha256sums arrays differ in length")

# Bundle Chromium's own copies of third-party libraries. A prebuilt package
# (cef-vaapi-bin) linked against Arch's copies breaks whenever one of them
# bumps its soname (libsimdutf.so.36 -> .37) until it is rebuilt. Keep only
# libraries whose sonames have been stable for years.
kept_system_libs = {"fontconfig": "fontconfig", "libdrm": "libdrm"}
system_libs_re = re.compile(r'(?ms)^declare -gA _system_libs=\(\n(?P<body>.*?)^\)')
match = system_libs_re.search(text)
if not match:
    fail("_system_libs array not found")
for key, package in kept_system_libs.items():
    if not re.search(rf'(?m)^[ \t]*\[{re.escape(key)}\]={re.escape(package)}[ \t]*$', match.group("body")):
        fail(f"_system_libs no longer lists [{key}]={package}")
system_libs_body = "  # cef-vaapi bundles every other library, see update-from-arch-cef.sh\n"
system_libs_body += "".join(f"  [{key}]={package}\n" for key, package in kept_system_libs.items())
text = text[:match.start("body")] + system_libs_body + text[match.end("body"):]

# Arch patches that only adapt Chromium or CEF to the system copies of
# now-bundled libraries. Arch may drop them; an applied one would break the
# bundled build (e.g. without libxml_visibility CEF cannot use bundled libxml).
unbundle_patches = [
    "chromium-147-simdutf-8.0-base-char.patch",
    "chromium-152-unbundle-minizip-undo-unicode.patch",
    "chromium-152-unbundle-opus-devtools.patch",
    "chromium-153-iamf-tools-unbundled-opus.patch",
    "cef-no-libxml-visibility-patch.patch",
]


def source_name(entry):
    return entry.strip("'\"").split("::")[0]


for name in unbundle_patches:
    entries = [source_name(entry) for entry in source_entries(text)]
    if name not in entries:
        continue
    index = entries.index(name)
    match = source_re.search(text)
    lines = match.group("body").splitlines(keepends=True)
    kept = [line for line in lines if source_name(line.strip()) != name]
    text = text[:match.start("body")] + "".join(kept) + text[match.end("body"):]
    match = sums_re.search(text)
    body = match.group("body")
    sums = list(re.finditer(r"'([0-9a-f]{64}|SKIP)'", body))
    if index > 0:
        start, end = sums[index - 1].end(), sums[index].end()
    else:
        start, end = sums[0].start(), sums[1].start()
    body = body[:start] + body[end:]
    text = text[:match.start("body")] + body + text[match.end("body"):]
    text, count = re.subn(rf'(?m)(?:^  #[^\n]*\n)*^  patch -Np1 -i \.\./{re.escape(name)}\n\n?', '', text)
    if count != 1:
        fail(f"expected exactly one application of {name}, found {count}")
if len(source_entries(text)) != len(sum_entries(text)):
    fail("source and sha256sums arrays differ in length after dropping unbundle patches")
# Arch renames these patches per Chromium version; stop on any new one so it is
# reviewed and added above instead of being applied to the bundled build.
for entry in source_entries(text):
    if re.search(r"unbundle|simdutf|libxml-visibility", source_name(entry)):
        fail(f"unreviewed unbundle patch {source_name(entry)}: add it to unbundle_patches")
# Opus is bundled now; Arch only needs it to build against the system copy.
text = re.sub(r"(?ms)(^makedepends=\(\n.*?)^  'opus'\n", r"\1", text, count=1)

sysroot_patch = "  patch -Np1 -i ../cef-no-sysroot.patch\n"
for name, comment in local_patches.items():
    patch_path = out_dir / name
    if not patch_path.is_file():
        fail(f"local patch missing: {name}")
    upstream_names = [source_name(entry) for entry in source_entries(text)]
    if name in upstream_names or (cache_dir / name).exists():
        fail(f"upstream unexpectedly already ships {name}")
    match = source_re.search(text)
    text = text[:match.end("body")] + f"  {name}\n" + text[match.end("body"):]
    digest = hashlib.sha256(patch_path.read_bytes()).hexdigest()
    match = sums_re.search(text)
    text = text[:match.end("body")] + f"\n            '{digest}'" + text[match.end("body"):]
    text = replace_once(text, sysroot_patch,
                        sysroot_patch + "\n" + comment + f"  patch -Np1 -i ../{name}\n",
                        "cef-no-sysroot patch application")
if len(source_entries(text)) != len(sum_entries(text)):
    fail("source and sha256sums arrays differ in length after adding local patches")
local_patch_list.write_text("".join(f"{name}\n" for name in local_patches))

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

  if declare -p replaces >/dev/null 2>&1 && (( ${#replaces[@]} > 0 )); then
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
sccache_opt_in = '''  # Optional C/C++ compiler cache. Fail rather than silently bypass an opt-in.
  # Chromium invokes rustc directly via its own wrapper, not Cargo/RUSTC_WRAPPER.
  if [[ ${CEF_VAAPI_SCCACHE:-0} == 1 ]]; then
    command -v sccache >/dev/null || {
      echo 'ERROR: CEF_VAAPI_SCCACHE=1 requires sccache in PATH' >&2
      return 1
    }
    _flags+=(
      'cc_wrapper="sccache"'
      'use_remoteexec=false' # reclient and cc_wrapper are mutually exclusive
      'strip_absolute_paths_from_debug_symbols=true'
    )
  fi

  # Optional cap on concurrent Python/Node build actions (GN defaults to the
  # host CPU count, which ignores container CPU and memory limits).
  if [[ -n ${CEF_VAAPI_ACTION_POOL_DEPTH:-} ]]; then
    _flags+=("action_pool_depth=${CEF_VAAPI_ACTION_POOL_DEPTH}")
  fi

'''
text = text.replace(export_marker, sccache_opt_in + '  _validate_cef_vaapi_invariants\n\n' + export_marker, 1)

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
mapfile -t local_patches < "$CACHE_DIR/local-patches"
(( ${#local_patches[@]} > 0 )) || die "no local patches recorded"
for local_patch in "${local_patches[@]}"; do
  grep -qF "patch -Np1 -i ../$local_patch" "$PKG" || die "$local_patch is not applied in prepare()"
  grep -qxF "	source = $local_patch" "$SRC" || die "$local_patch missing from .SRCINFO sources"
done
grep -q 'pkgbase = cef-vaapi' "$SRC" || die ".SRCINFO pkgbase check failed"

log "Update complete: $OUTPUT_DIR"
log "Created/updated PKGBUILD, .SRCINFO, patches, FindCEF.cmake, LICENSE.ARCH-ISC, REUSE.toml, LICENSES/"
