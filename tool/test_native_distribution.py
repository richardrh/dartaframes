import subprocess
import sys
import json
import tempfile
import unittest
from pathlib import Path

from native_distribution import ABI_VERSION, SYMBOLS, TARGETS, archive_name, raw_asset_name, verify_one


SCRIPT = Path(__file__).with_name("native_distribution.py")


class NativeDistributionTest(unittest.TestCase):
    def package_command(self, root, library, target, version, output_dir):
        license_file = root / "LICENSE"
        third_party = root / "THIRD_PARTY_LICENSES.txt"
        license_file.write_text("project license\n")
        third_party.write_text("dependency licenses\n")
        return [sys.executable, str(SCRIPT), "package", "--library", str(library),
                "--target", target, "--version", version, "--output-dir", str(output_dir),
                "--license", str(license_file), "--third-party-licenses", str(third_party)]

    def test_abi_two_manifest_declares_core_and_arrow_symbols(self):
        self.assertEqual(ABI_VERSION, 2)
        self.assertEqual(len(SYMBOLS), 18)
        self.assertIn("df_invoke", SYMBOLS)
        self.assertIn("df_frame_import_arrow_stream", SYMBOLS)

    def test_packages_and_indexes_all_targets(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            dist = root / "dist"
            for target, name in TARGETS.items():
                library = root / target / name
                library.parent.mkdir(parents=True)
                library.write_bytes(("test-library-" + target).encode())
                subprocess.run(self.package_command(
                    root, library, target, "1.2.3-test.1", dist), check=True)
                archive = dist / archive_name("1.2.3-test.1", target)
                verify_one(archive, archive.with_name(archive.name + ".sha256"))
                raw = dist / raw_asset_name("1.2.3-test.1", target)
                self.assertEqual(raw.read_bytes(), library.read_bytes())
                self.assertTrue(raw.with_name(raw.name + ".sha256").is_file())
            (dist / "LICENSE").write_bytes((root / "LICENSE").read_bytes())
            (dist / "THIRD_PARTY_LICENSES.txt").write_bytes(
                (root / "THIRD_PARTY_LICENSES.txt").read_bytes())
            subprocess.run(
                [sys.executable, str(SCRIPT), "index", "--directory", str(dist),
                 "--version", "1.2.3-test.1", "--output-dir", str(dist)],
                check=True,
            )
            self.assertEqual(len((dist / "SHA256SUMS").read_text().splitlines()), 12)
            index = dist / "native-assets.json"
            manifest = json.loads(index.read_text())
            self.assertEqual(len(manifest["artifacts"]), 5)
            self.assertIn("raw_sha256", manifest["artifacts"][0])
            generated = root / "native_release_metadata.dart"
            subprocess.run(
                [sys.executable, str(SCRIPT), "generate-dart", "--index", str(index),
                 "--output", str(generated)], check=True,
            )
            generated_text = generated.read_text()
            self.assertIn("rawSha256: '", generated_text)
            self.assertNotIn("rawSha256: null", generated_text)

    def test_index_rejects_raw_asset_that_differs_from_archive(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for target, name in TARGETS.items():
                library = root / target / name
                library.parent.mkdir(parents=True)
                library.write_bytes(("library-" + target).encode())
                subprocess.run(self.package_command(
                    root, library, target, "1", root), check=True)
            target = next(iter(TARGETS))
            raw = root / raw_asset_name("1", target)
            raw.write_bytes(b"corrupt")
            with self.assertRaises(subprocess.CalledProcessError):
                subprocess.run(
                    [sys.executable, str(SCRIPT), "index", "--directory", str(root),
                     "--version", "1", "--output-dir", str(root)], check=True,
                )

    def test_rejects_bad_checksum(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            target = "x86_64-pc-windows-msvc"
            library = root / TARGETS[target]
            library.write_bytes(b"not-a-real-dll")
            subprocess.run(self.package_command(
                root, library, target, "1", root), check=True)
            archive = root / archive_name("1", target)
            sidecar = archive.with_name(archive.name + ".sha256")
            sidecar.write_text("0" * 64 + f"  {archive.name}\n")
            with self.assertRaises(Exception):
                verify_one(archive, sidecar)


if __name__ == "__main__":
    unittest.main()
