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
        self.assertIn("ref=1:154.0.34-2", stable.metadata(
            {"pkgver": "154.0.34", "pkgrel": 2, "epoch": 1}))
        with self.assertRaises(ValueError):
            stable.metadata({"pkgver": "bad\nref=main", "pkgrel": 1})

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


if __name__ == "__main__":
    unittest.main()
