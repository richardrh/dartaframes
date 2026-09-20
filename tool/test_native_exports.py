import unittest
from pathlib import Path

from native_exports import (
    ExportError,
    defined_exports,
    require_abi_exports,
    require_abi_exports_from_coff_exports,
)
from native_distribution import SYMBOLS


FIXTURES = Path(__file__).with_name("testdata")


class NativeExportsTest(unittest.TestCase):
    def test_parses_llvm_nm_elf_listing(self):
        listing = (FIXTURES / "llvm-nm-elf.txt").read_text(encoding="utf-8")
        exports = require_abi_exports(listing)
        self.assertIn("df_abi_version", exports)
        self.assertNotIn("undefined_dependency", exports)

    def test_parses_macho_leading_underscores(self):
        listing = (FIXTURES / "llvm-nm-macho.txt").read_text(encoding="utf-8")
        self.assertEqual(len(require_abi_exports(listing)), 18)

    def test_parses_coff_export_table(self):
        names = "\n".join(f"    Name: {name}" for name in sorted(SYMBOLS))
        exports = require_abi_exports_from_coff_exports(names)
        self.assertEqual(len(exports), 18)

    def test_rejects_missing_coff_export(self):
        with self.assertRaises(ExportError):
            require_abi_exports_from_coff_exports("    Name: df_invoke\n")

    def test_rejects_missing_advertised_symbol(self):
        listing = (FIXTURES / "llvm-nm-elf.txt").read_text(encoding="utf-8")
        listing = listing.replace("0000000000000010 T df_invoke\n", "")
        with self.assertRaises(ExportError):
            require_abi_exports(listing)

    def test_ignores_headers_and_undefined_symbols(self):
        exports = defined_exports("library.so:\n                 U df_invoke\n000 T extra\n")
        self.assertEqual(exports, {"extra"})


if __name__ == "__main__":
    unittest.main()
