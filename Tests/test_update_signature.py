from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class UpdateSignatureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workspace = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.workspace.cleanup)
        cls.root = Path(cls.workspace.name)
        cls.archive = cls.root / "update.zip"
        cls.verifier = cls.root / "verify-update"
        subprocess.run(["swiftc", str(ROOT / "scripts/verify-update.swift"), "-o", str(cls.verifier)],
                       check=True, capture_output=True)
        fixture = cls.root / "fixture.swift"
        fixture.write_text('''import Foundation
import CryptoKit
let key = Curve25519.Signing.PrivateKey()
let data = Data("검증용 업데이트".utf8)
try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print(key.publicKey.rawRepresentation.base64EncodedString())
print(try key.signature(for: data).base64EncodedString())
''')
        result = subprocess.run(["swift", str(fixture), str(cls.archive)], check=True, capture_output=True, text=True)
        cls.public_key, cls.signature = result.stdout.strip().splitlines()

    def verify(self, archive, signature=None):
        return subprocess.run([str(self.verifier), str(archive), signature or self.signature, self.public_key],
                              capture_output=True, text=True)

    def test_valid_archive_is_accepted(self):
        self.assertEqual(self.verify(self.archive).returncode, 0)

    def test_modified_archive_is_rejected(self):
        modified = self.root / "modified.zip"
        modified.write_bytes(self.archive.read_bytes() + b"changed")
        self.assertNotEqual(self.verify(modified).returncode, 0)

    def test_malformed_signature_is_rejected(self):
        self.assertNotEqual(self.verify(self.archive, signature="invalid-signature").returncode, 0)
