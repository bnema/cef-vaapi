#!/usr/bin/env python3
"""Offline regression checks for stable selection and prepared-tree reuse."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("stable", ROOT / "scripts/arch-cef-stable.py")
stable = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stable)


class PolicyTests(unittest.TestCase):
    def test_stable_tag(self):
        self.assertEqual(stable.metadata({"pkgver": "154.0.34", "pkgrel": 2}),
                         "pkgver=154.0.34\npkgrel=2\nref=154.0.34-2")
        self.assertIn("ref=1-154.0.34-2", stable.metadata(
            {"pkgver": "154.0.34", "pkgrel": 2, "epoch": 1}))
        with self.assertRaises(ValueError):
            stable.metadata({"pkgver": "bad\nref=main", "pkgrel": 1})

    def test_sccache_flags(self):
        pkgbuild = (ROOT / "PKGBUILD").read_text()
        block = pkgbuild[pkgbuild.index('  # Optional C/C++ compiler cache.'):
                         pkgbuild.index('  _validate_cef_vaapi_invariants\n')]
        for enabled, available, success in (("0", False, True),
                                             ("1", False, False),
                                             ("1", True, True)):
            with self.subTest(enabled=enabled, available=available):
                script = 'set -e\n_flags=()\nCEF_VAAPI_SCCACHE=' + enabled + '\n'
                # Mock discovery, independent of whether the host has sccache.
                script += 'command() { return ' + ('0' if available else '1') + '; }\n'
                script += 'configure() {\n' + block + '\n}\nconfigure\n'
                script += 'printf "%s\\n" "${_flags[@]}"\n'
                result = subprocess.run(["bash", "-c", script], capture_output=True, text=True)
                self.assertEqual(result.returncode == 0, success, result.stderr)
                if enabled == "1" and available:
                    self.assertEqual(result.stdout.splitlines(), [
                        'cc_wrapper="sccache"', 'use_remoteexec=false',
                        'strip_absolute_paths_from_debug_symbols=true'])
                else:
                    self.assertNotIn('cc_wrapper=', result.stdout)

    def test_updater_keeps_build_options(self):
        # The daily sync regenerates PKGBUILD from this template.
        pkgbuild = (ROOT / "PKGBUILD").read_text()
        updater = (ROOT / "scripts/update-from-arch-cef.sh").read_text()
        start = '  # Optional C/C++ compiler cache.'
        block = pkgbuild[pkgbuild.index(start):pkgbuild.index('  _validate_cef_vaapi_invariants\n')]
        self.assertIn(block, updater)

    def test_local_patches_applied(self):
        # The daily sync rebuilds PKGBUILD from Arch's; cef-vaapi's own patches
        # must survive it, be listed with a current checksum and be applied.
        import hashlib
        import re
        pkgbuild = (ROOT / "PKGBUILD").read_text()
        updater = (ROOT / "scripts/update-from-arch-cef.sh").read_text()
        body = re.search(r'(?ms)^source=\(\n(.*?)^\)', pkgbuild).group(1)
        sources = [line.strip() for line in body.splitlines()
                   if line.strip() and not line.strip().startswith("#")]
        sums = re.findall(r"'([0-9a-f]{64}|SKIP)'",
                          re.search(r'(?ms)^sha256sums=\((.*?)\)', pkgbuild).group(1))
        self.assertEqual(len(sources), len(sums))
        names = re.findall(r'^    "([^"]+\.(?:patch|diff))": \(', updater, re.M)
        self.assertTrue(names, "no local patches found in the updater")
        for name in names:
            with self.subTest(patch=name):
                self.assertIn(name, sources)
                digest = hashlib.sha256((ROOT / name).read_bytes()).hexdigest()
                self.assertEqual(sums[sources.index(name)], digest)
                self.assertIn(f"  patch -Np1 -i ../{name}\n", pkgbuild)

    def test_action_pool_depth(self):
        pkgbuild = (ROOT / "PKGBUILD").read_text()
        block = pkgbuild[pkgbuild.index('  # Optional cap on concurrent'):
                         pkgbuild.index('  _validate_cef_vaapi_invariants\n')]
        for depth, expected in (("", []), ("4", ["action_pool_depth=4"])):
            script = '_flags=()\nCEF_VAAPI_ACTION_POOL_DEPTH=' + depth + '\n' + block
            script += 'printf "%s\\n" "${_flags[@]}"\n'
            out = subprocess.run(["bash", "-c", script], capture_output=True, text=True).stdout
            self.assertEqual([l for l in out.splitlines() if l], expected)

    def test_prepare_policy(self):
        workflow = (ROOT / ".github/workflows/build-vaapi.yml").read_text()
        block = textwrap.dedent(workflow[workflow.index('          if [[ -d "$out_dir"'):workflow.index('          max_attempts=2')])
        for key in (None, "old", "current"):
            for fail in (False, True):
                with self.subTest(key=key, fail=fail), tempfile.TemporaryDirectory() as tmp:
                    root = Path(tmp)
                    (root / "src/out").mkdir(parents=True)
                    if key is not None:
                        (root / "src/key").write_text(key)
                    script = '''set -e
out_dir=src/out
key_file=src/key
build_key=current
makepkg_args=()
makepkg() {
  echo "$*" >> calls
  mkdir -p src/out
  return FAIL
}
'''.replace("FAIL", "1" if fail else "0") + block + '\nprintf "%s\\n" "${makepkg_args[*]}" > args\n'
                    result = subprocess.run(["bash", "-c", script], cwd=root, capture_output=True)
                    if key == "current":
                        self.assertEqual(result.returncode, 0)
                        self.assertFalse((root / "calls").exists())
                    elif fail:
                        self.assertNotEqual(result.returncode, 0)
                        self.assertFalse((root / "src/key").exists())
                    else:
                        self.assertEqual(result.returncode, 0, result.stderr)
                        self.assertIn("--nobuild", (root / "calls").read_text())
                        self.assertEqual((root / "src/key").read_text().strip(), "current")
                    if result.returncode == 0:
                        self.assertIn("--noprepare", (root / "args").read_text())

    def test_release_state(self):
        # A network error must fail, never read as "missing" (which rebuilds
        # and replaces a good release). Each API call is faked separately.
        ok_404 = "echo 'gh: Not Found (HTTP 404)' >&2; exit 1"
        timeout = "echo 'dial tcp: i/o timeout' >&2; exit 1"
        cases = (
            # (releases/tags answer, releases list answer, exit code, state, calls)
            ("echo 1", timeout, 0, "published", 1),
            (ok_404, "echo 42", 0, "draft", 2),
            (ok_404, "true", 0, "missing", 2),
            (timeout, "true", 1, "", 3),
            (ok_404, timeout, 1, "", 6),
        )
        for tags, listing, code, state, calls in cases:
            with self.subTest(tags=tags, listing=listing), tempfile.TemporaryDirectory() as tmp:
                gh = Path(tmp) / "gh"
                gh.write_text(
                    "#!/bin/sh\necho call >> \"$(dirname \"$0\")/calls\"\n"
                    "case \"$*\" in\n"
                    f"  *releases/tags/*) {tags} ;;\n"
                    f"  *releases\\?*) {listing} ;;\n"
                    "  *) exit 9 ;;\nesac\n")
                gh.chmod(0o755)
                env = {"PATH": f"{tmp}:/usr/bin:/bin", "RELEASE_STATE_DELAY": "0"}
                result = subprocess.run(
                    ["bash", str(ROOT / "scripts/github-release-state.sh"), "owner/repo", "tag"],
                    env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, code, result.stderr)
                self.assertEqual(result.stdout.strip(), state)
                self.assertEqual((Path(tmp) / "calls").read_text().count("call"), calls)


if __name__ == "__main__":
    unittest.main()
