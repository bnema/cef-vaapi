#!/usr/bin/env bash
# Print the depends of cef-vaapi-bin, one per line, from a built cef-vaapi package.
#
# cef-vaapi bundles most third-party libraries but still links some system
# libraries (glibc, nss, glib, libffi, fontconfig, ...). The package's own
# depends name packages without a version, so pacman would let a soname bump
# through and leave libcef.so unable to load. Pin each linked soname the way
# Arch does (e.g. libffi.so=8-64) so pacman refuses that upgrade until a
# rebuilt package exists. Linked libraries whose package declares no soname
# provide still get their package as a plain depend.
#
# Fails if a linked library is missing on this system: the package was built
# against libraries that differ from the ones installed here.
set -euo pipefail

pkgfile=${1:?usage: bin-depends.sh <cef-vaapi package file>}
[[ -f $pkgfile ]] || { echo "ERROR: package not found: $pkgfile" >&2; exit 1; }

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
bsdtar -xpf "$pkgfile" -C "$tmpdir" .PKGINFO usr/lib/cef

# Package depends declared by the build (unversioned names).
sed -n 's/^depend = //p' "$tmpdir/.PKGINFO" > "$tmpdir/depends"

# Libraries the package ships itself are not system dependencies.
find "$tmpdir/usr/lib/cef" \( -type f -o -type l \) -name '*.so*' -printf '%f\n' | sort -u > "$tmpdir/bundled"

while IFS= read -r -d '' file; do
  # Non-ELF files (resources, JSON) have no dynamic section.
  { readelf -d "$file" 2>/dev/null || true; } | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p'
done < <(find "$tmpdir/usr/lib/cef" -type f -print0) | sort -u > "$tmpdir/needed"

status=0
while IFS= read -r soname; do
  grep -qxF "$soname" "$tmpdir/bundled" && continue
  lib="/usr/lib/$soname"
  if [[ ! -e $lib ]]; then
    echo "ERROR: $soname is linked but missing on this system" >&2
    status=1
    continue
  fi
  owner=$(pacman -Qqo "$lib")
  provides=$(pacman -Qi "$owner" | sed -n 's/^Provides *: //p' | tr -s ' ' '\n')
  # Pin versioned sonames their package declares, like Arch's soname depends.
  if [[ $soname =~ ^(.+\.so)\.([0-9]+)$ ]] &&
    grep -qxF "${BASH_REMATCH[1]}=${BASH_REMATCH[2]}-64" <<< "$provides"; then
    echo "${BASH_REMATCH[1]}=${BASH_REMATCH[2]}-64" >> "$tmpdir/depends"
  else
    echo "$owner" >> "$tmpdir/depends"
  fi
done < "$tmpdir/needed"
(( status == 0 )) || exit 1

sort -u "$tmpdir/depends"
