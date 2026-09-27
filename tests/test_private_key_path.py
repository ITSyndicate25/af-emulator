from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class PrivateKeyPathTests(unittest.TestCase):
    def test_server_private_key_path_matches_documented_setup(self):
        server = (ROOT / "server" / "assaultfire_server_v143b.py").read_text(
            encoding="utf-8", errors="replace"
        )
        boot = (ROOT / "server" / "assaultfire_boot.py").read_text(
            encoding="utf-8", errors="replace"
        )

        self.assertIn(
            'DEFAULT_PRIVATE_KEY_PATH = Path(__file__).resolve().with_name("PRIVATE.PEM")',
            server,
        )
        self.assertIn("resolve_private_key_path(", server)
        self.assertIn('env.get("AF_PRIVATE_KEY")', boot)
        self.assertIn('env.get("AF_PRIVATE_KEY_PATH")', boot)

    def test_documented_override_matches_server(self):
        getting_started = (ROOT / "docs" / "GETTING_STARTED.md").read_text(
            encoding="utf-8", errors="replace"
        )
        boot = (ROOT / "server" / "assaultfire_boot.py").read_text(
            encoding="utf-8", errors="replace"
        )

        self.assertIn("$env:AF_PRIVATE_KEY", getting_started)
        self.assertIn('env.get("AF_PRIVATE_KEY")', boot)


if __name__ == "__main__":
    unittest.main()
