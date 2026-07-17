import importlib.util
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/release_consistency.py"
SPEC = importlib.util.spec_from_file_location("release_consistency", SCRIPT)
release_consistency = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = release_consistency
SPEC.loader.exec_module(release_consistency)


class ReleaseConsistencyTests(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.root = Path(self.tempdir.name)
        for ref in release_consistency.RELEASE_REFERENCES:
            target = self.root / ref.path
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / ref.path, target)

    def tearDown(self):
        self.tempdir.cleanup()

    def run_check(self):
        return subprocess.run(
            [sys.executable, str(SCRIPT), "--root", str(self.root), "--tag", "v0.6.0"],
            text=True,
            capture_output=True,
        )

    def test_current_release_is_consistent(self):
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_each_single_stale_reference_fails(self):
        for ref in release_consistency.RELEASE_REFERENCES:
            with self.subTest(reference=ref.name):
                path = self.root / ref.path
                original = path.read_text()
                matches = list(release_consistency.re.finditer(ref.pattern, original, flags=release_consistency.re.MULTILINE))
                self.assertEqual(len(matches), 1)
                match = matches[0]
                stale = match.group(1) + "v9.9.9"
                if match.lastindex and match.lastindex >= 3:
                    stale += match.group(3)
                path.write_text(original[: match.start()] + stale + original[match.end() :])
                result = self.run_check()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(ref.name, result.stderr)
                path.write_text(original)

    def test_set_updates_and_rechecks_the_inventory(self):
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--root", str(self.root), "--set", "v9.9.9"],
            text=True,
            capture_output=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(release_consistency.inspect(self.root, "v9.9.9"), [])

    def test_set_preserves_non_ascii_utf8_bytes_outside_tag_replacements(self):
        readme = self.root / "README.md"
        original = "Release notes — café\n".encode(encoding="utf-8") + readme.read_bytes()
        readme.write_bytes(original)
        reference = next(
            ref for ref in release_consistency.RELEASE_REFERENCES if ref.path == "README.md"
        )
        original_text = original.decode(encoding="utf-8")
        match = release_consistency.re.search(
            reference.pattern, original_text, flags=release_consistency.re.MULTILINE
        )
        self.assertIsNotNone(match)
        assert match is not None
        replacement = match.group(1) + "v9.9.9" + match.group(3)
        expected = (
            original_text[: match.start()] + replacement + original_text[match.end() :]
        ).encode(encoding="utf-8")

        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--root", str(self.root), "--set", "v9.9.9"],
            text=True,
            capture_output=True,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(readme.read_bytes(), expected)

    def test_set_writes_nothing_when_inventory_validation_fails(self):
        first = release_consistency.RELEASE_REFERENCES[0]
        first_path = self.root / first.path
        original = first_path.read_text()
        missing = release_consistency.RELEASE_REFERENCES[-1]
        (self.root / missing.path).unlink()

        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--root", str(self.root), "--set", "v9.9.9"],
            text=True,
            capture_output=True,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(first_path.read_text(), original)

    def test_set_rolls_back_if_a_file_replace_fails(self):
        originals = {
            self.root / ref.path: (self.root / ref.path).read_text()
            for ref in release_consistency.RELEASE_REFERENCES
        }
        real_replace = release_consistency.os.replace
        second_path = self.root / release_consistency.RELEASE_REFERENCES[2].path
        failed = False

        def fail_once(source, destination):
            nonlocal failed
            if Path(destination) == second_path and not failed:
                failed = True
                raise OSError("simulated replace failure")
            return real_replace(source, destination)

        with mock.patch.object(release_consistency.os, "replace", side_effect=fail_once):
            with self.assertRaisesRegex(OSError, "simulated replace failure"):
                release_consistency.inspect(self.root, "v9.9.9", update=True)

        self.assertTrue(failed)
        for path, original in originals.items():
            self.assertEqual(path.read_text(), original, path)


class UpgradeProvenanceTests(unittest.TestCase):
    @staticmethod
    def _archive(tmp, marker="v0.6.0", missing=None):
        archive_root = tmp / "archive" / "flightdeck-commit" / "template-app"
        (archive_root / "docs").mkdir(parents=True)
        (archive_root / ".github/workflows").mkdir(parents=True)
        for name in ("AGENTS.md", "CLAUDE.md", "app-manifest.schema.json", "main.tf", "Makefile"):
            if name != missing:
                (archive_root / name).write_text(f"release {name}\n")
        (archive_root / "docs/pipeline.md").write_text("release docs\n")
        if missing != ".github/workflows/ci.yml":
            (archive_root / ".github/workflows/ci.yml").write_text("name: ci\n")
        if marker is not None:
            (archive_root / ".flightdeck-version").write_text(f"{marker}\n")
        archive = tmp / "release.tar.gz"
        with tarfile.open(archive, "w:gz") as tar:
            tar.add(archive_root.parents[1], arcname="flightdeck-commit")
        return archive

    @staticmethod
    def _fake_tools(tmp, archive, tag="v0.6.0", fail_hash=False, invalid_hash=False):
        fakebin = tmp / "bin"
        fakebin.mkdir()
        (fakebin / "git").write_text(
            "#!/bin/sh\n"
            "if [ \"$1\" = status ]; then exit 0; fi\n"
            "printf '%s\\trefs/tags/%s\\n' '0123456789abcdef0123456789abcdef01234567' \"$FAKE_TAG\"\n"
        )
        (fakebin / "curl").write_text(
            "#!/bin/sh\n"
            "printf '%s\\n' \"$*\" >> \"$CURL_LOG\"\n"
            "while [ $# -gt 0 ]; do [ \"$1\" = -o ] && { cp \"$ARCHIVE\" \"$2\"; exit; }; shift; done\n"
        )
        (fakebin / "git").chmod(0o755)
        (fakebin / "curl").chmod(0o755)
        if fail_hash:
            (fakebin / "sha256sum").write_text("#!/bin/sh\nexit 1\n")
            (fakebin / "sha256sum").chmod(0o755)
        elif invalid_hash:
            (fakebin / "sha256sum").write_text("#!/bin/sh\nprintf 'not-a-sha  %s\\n' \"$1\"\n")
            (fakebin / "sha256sum").chmod(0o755)
        env = dict(**__import__("os").environ)
        env["PATH"] = f"{fakebin}:{env['PATH']}"
        env["ARCHIVE"] = str(archive)
        env["CURL_LOG"] = str(tmp / "curl.log")
        env["FAKE_TAG"] = tag
        return env

    def test_bad_embedded_release_marker_aborts_before_replacement(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            app = tmp / "app"
            app.mkdir()
            shutil.copy2(ROOT / "template-app/Makefile", app / "Makefile")
            (app / "AGENTS.md").write_text("original\n")

            archive = self._archive(tmp, marker="v9.9.9")

            env = self._fake_tools(tmp, archive)
            result = subprocess.run(
                ["make", "upgrade", "TAG=v0.6.0", "REPO_URL=https://example.test/flightdeck"],
                cwd=app,
                env=env,
                text=True,
                capture_output=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("release marker", result.stdout + result.stderr)
            self.assertEqual((app / "AGENTS.md").read_text(), "original\n")
            self.assertFalse((app / ".flightdeck-provenance").exists())

    def test_verified_upgrade_records_immutable_provenance(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            app = tmp / "app"
            app.mkdir()
            shutil.copy2(ROOT / "template-app/Makefile", app / "Makefile")

            archive = self._archive(tmp)

            result = subprocess.run(
                ["make", "upgrade", "TAG=v0.6.0", "REPO_URL=https://example.test/flightdeck"],
                cwd=app,
                env=self._fake_tools(tmp, archive),
                text=True,
                capture_output=True,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            provenance = (app / ".flightdeck-provenance").read_text()
            self.assertIn("tag=v0.6.0\n", provenance)
            self.assertIn("commit=0123456789abcdef0123456789abcdef01234567\n", provenance)
            self.assertRegex(provenance, r"archive_sha256=[0-9a-f]{64}\n")
            curl_args = (tmp / "curl.log").read_text()
            self.assertIn("/archive/0123456789abcdef0123456789abcdef01234567.tar.gz", curl_args)
            self.assertNotIn("/archive/refs/tags/", curl_args)

    def test_legacy_downgrade_without_marker_records_provenance(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            app = tmp / "app"
            app.mkdir()
            shutil.copy2(ROOT / "template-app/Makefile", app / "Makefile")
            archive = self._archive(tmp, marker=None)

            result = subprocess.run(
                ["make", "upgrade", "TAG=v0.4.0", "REPO_URL=https://example.test/flightdeck"],
                cwd=app,
                env=self._fake_tools(tmp, archive, tag="v0.4.0"),
                text=True,
                capture_output=True,
            )

            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual((app / ".flightdeck-version").read_text(), "v0.4.0\n")
            self.assertIn("commit=0123456789abcdef0123456789abcdef01234567", (app / ".flightdeck-provenance").read_text())

    def test_malformed_archive_aborts_before_replacement(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            app = tmp / "app"
            app.mkdir()
            shutil.copy2(ROOT / "template-app/Makefile", app / "Makefile")
            (app / "AGENTS.md").write_text("original\n")
            archive = self._archive(tmp, missing="CLAUDE.md")

            result = subprocess.run(
                ["make", "upgrade", "TAG=v0.6.0", "REPO_URL=https://example.test/flightdeck"],
                cwd=app,
                env=self._fake_tools(tmp, archive),
                text=True,
                capture_output=True,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("malformed release archive", result.stdout + result.stderr)
            self.assertEqual((app / "AGENTS.md").read_text(), "original\n")
            self.assertFalse((app / ".flightdeck-provenance").exists())

    def test_hash_failure_aborts_before_replacement(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            app = tmp / "app"
            app.mkdir()
            shutil.copy2(ROOT / "template-app/Makefile", app / "Makefile")
            (app / "AGENTS.md").write_text("original\n")
            archive = self._archive(tmp)

            result = subprocess.run(
                ["make", "upgrade", "TAG=v0.6.0", "REPO_URL=https://example.test/flightdeck"],
                cwd=app,
                env=self._fake_tools(tmp, archive, fail_hash=True),
                text=True,
                capture_output=True,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("failed to calculate release archive SHA-256", result.stdout + result.stderr)
            self.assertEqual((app / "AGENTS.md").read_text(), "original\n")
            self.assertFalse((app / ".flightdeck-provenance").exists())

    def test_invalid_hash_aborts_before_replacement(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            app = tmp / "app"
            app.mkdir()
            shutil.copy2(ROOT / "template-app/Makefile", app / "Makefile")
            (app / "AGENTS.md").write_text("original\n")
            archive = self._archive(tmp)

            result = subprocess.run(
                ["make", "upgrade", "TAG=v0.6.0", "REPO_URL=https://example.test/flightdeck"],
                cwd=app,
                env=self._fake_tools(tmp, archive, invalid_hash=True),
                text=True,
                capture_output=True,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("invalid SHA-256", result.stdout + result.stderr)
            self.assertEqual((app / "AGENTS.md").read_text(), "original\n")
            self.assertFalse((app / ".flightdeck-provenance").exists())


if __name__ == "__main__":
    unittest.main()
