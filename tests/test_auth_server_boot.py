from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SERVER_DIR = ROOT / "server"
if str(SERVER_DIR) not in sys.path:
    sys.path.insert(0, str(SERVER_DIR))

from assaultfire_auth import parse_client_dh_plaintext
from assaultfire_boot import resolve_private_key_path, server_only_requested


P_PRIME = int(
    "BB2A43DF39322DAAC8C3B30C9F21E13F"
    "646B7234A846231038C087F3408A558D"
    "A8AA1912AE906DEF3E781E39FE172B20"
    "3A6B8452056B3C9CB21237CAC3F5AA1B",
    16,
)


class AuthMinimalBignumTests(unittest.TestCase):
    def test_captured_67_byte_rsa_plaintext_is_accepted(self):
        wire = bytes.fromhex(
            "d0e2861afd7a57c20d4c60a9f90b037d8dacf5fa485a85e815e8e0f64e15c858"
            "ec31682b0016dc09ebd25c76250e44b6bb1bec2c59ba0a6ec27a9bffd0a041"
        )
        self.assertEqual(len(wire), 63)
        hello = parse_client_dh_plaintext(
            bytes.fromhex("00006b7d") + wire,
            prime=P_PRIME,
        )
        self.assertEqual(hello.nonce, 0x00006B7D)
        self.assertEqual(hello.wire_public, wire)
        self.assertEqual(len(hello.canonical_public), 64)
        self.assertEqual(hello.canonical_public[0], 0)
        self.assertEqual(hello.canonical_public[1:], wire)

    def test_normal_64_byte_public_value_is_unchanged(self):
        wire = (P_PRIME // 2).to_bytes(64, "big")
        hello = parse_client_dh_plaintext(b"\x12\x34\x56\x78" + wire, prime=P_PRIME)
        self.assertEqual(hello.canonical_public, wire)
        self.assertEqual(len(hello.wire_public), 64)

    def test_invalid_lengths_and_public_values_are_rejected(self):
        with self.assertRaises(ValueError):
            parse_client_dh_plaintext(b"\x00" * 4, prime=P_PRIME)
        with self.assertRaises(ValueError):
            parse_client_dh_plaintext(b"\x00" * 69, prime=P_PRIME)
        with self.assertRaises(ValueError):
            parse_client_dh_plaintext(b"\x00" * 4 + b"\x01", prime=P_PRIME)


class ServerOnlyBootTests(unittest.TestCase):
    def test_server_only_flag_and_environment(self):
        self.assertTrue(server_only_requested(["--server-only"], {}))
        self.assertTrue(server_only_requested([], {"AF_SERVER_ONLY": "1"}))
        self.assertFalse(server_only_requested([], {}))

    def test_copied_server_finds_parent_repo_private_key(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            copied = root / "TEST" / "assaultfire_server_v143b.py"
            copied.parent.mkdir()
            copied.write_text("# copy\n", encoding="utf-8")
            key = root / "server" / "PRIVATE.PEM"
            key.parent.mkdir()
            key.write_text("test-key\n", encoding="utf-8")

            found = resolve_private_key_path(
                script_path=copied,
                argv=[],
                env={},
                cwd=copied.parent,
            )
            self.assertEqual(found, key.resolve())

    def test_explicit_private_key_has_priority(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            explicit = root / "elsewhere" / "key.pem"
            found = resolve_private_key_path(
                script_path=root / "TEST" / "server.py",
                argv=["--private-key", str(explicit)],
                env={"AF_PRIVATE_KEY": str(root / "wrong.pem")},
                cwd=root,
            )
            self.assertEqual(found, explicit.resolve())

    def test_server_integration_keeps_sensitive_rsa_plaintext_debug_only(self):
        source = (SERVER_DIR / "assaultfire_server_v143b.py").read_text(
            encoding="utf-8", errors="replace"
        )
        needle = 'f"[AUTH] RSA plaintext={plain.hex()}"'
        pos = source.index(needle)
        self.assertIn("if DEBUG_AUTH_HEX:", source[max(0, pos - 180):pos])
        self.assertIn("parse_client_dh_plaintext(", source)
        self.assertIn("--server-only", source)
        self.assertIn("local game launch helpers", source)


if __name__ == "__main__":
    unittest.main()
