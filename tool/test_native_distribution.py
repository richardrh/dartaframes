import subprocess
import sys
import json
import tempfile
import unittest
from pathlib import Path

from native_distribution import ABI_VERSION, TARGETS, archive_name, raw_asset_name, verify_one


SCRIPT = Path(__file__).with_name("native_distribution.py")


class NativeDistributionTest(unittest.TestCase):
    def package_command(self, root, library, target, version, output_dir):
        license_file = root / "LICENSE"
        third_party = root / "THIRD_PARTY_LICENSES.txt"
        license_file.write_bytes(b"project license\r\n")
        third_party.write_bytes(b"dependency licenses\r\n")
        return [sys.executable, str(SCRIPT), "package", "--library", str(library),
                "--target", target, "--version", version, "--output-dir", str(output_dir),
                "--license", str(license_file), "--third-party-licenses", str(third_party)]

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

    def test_new_version_cannot_inherit_promoted_pins(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            metadata = root / "lib/src/native_release_metadata.dart"
            reviewed = root / "native-assets.json"
            reviewed.write_text(json.dumps({
                "schema_version": 1, "abi_version": ABI_VERSION,
                "package": "dartaframes_polars_ffi", "version": "0.1.0",
                "artifacts": [
                    {"target": target, "archive": archive_name("0.1.0", target),
                     "archive_sha256": "a" * 64,
                     "raw_asset": raw_asset_name("0.1.0", target),
                     "raw_sha256": "b" * 64, "raw_size": 128}
                    for target in TARGETS
                ],
            }))
            subprocess.run(
                [sys.executable, str(SCRIPT), "generate-dart", "--index",
                 str(reviewed), "--output", str(metadata)], check=True,
            )
            validator = root / ".github/scripts/validate_release.py"
            validator.parent.mkdir(parents=True)
            validator.write_bytes(
                (SCRIPT.parent.parent / ".github/scripts/validate_release.py").read_bytes()
            )
            cargo = root / "native/polars_ffi/Cargo.toml"
            cargo.parent.mkdir(parents=True)

            def validate(version, promoted=False):
                (root / "pubspec.yaml").write_text(
                    f"name: dartaframes_polars\nversion: {version}\n"
                )
                cargo.write_text(f'[package]\nversion = "{version}"\n')
                command = [sys.executable, str(validator), version]
                if promoted:
                    command.append("--require-promoted")
                return subprocess.run(command, capture_output=True, text=True)

            self.assertEqual(validate("0.1.0", promoted=True).returncode, 0)
            subprocess.run(
                [sys.executable, str(SCRIPT), "init-dart", "--version", "0.1.1",
                 "--output", str(metadata)], check=True,
            )
            self.assertEqual(validate("0.1.1").returncode, 0)
            self.assertNotEqual(validate("0.1.1", promoted=True).returncode, 0)

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
