import os
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from client import BridgeClientError, atomic_request, owned_file  # noqa: E402


class ClientFileTests(unittest.TestCase):
    def test_rejects_world_readable_file(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "session.json"
            path.write_bytes(b"{}")
            path.chmod(0o644)
            with self.assertRaises(BridgeClientError):
                owned_file(path, 2048)

    def test_rejects_symlink(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "target"
            target.write_bytes(b"{}")
            target.chmod(0o600)
            link = Path(directory) / "link"
            link.symlink_to(target)
            with self.assertRaises(OSError):
                owned_file(link, 2048)

    def test_atomic_request_is_private(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "request.json"
            atomic_request(path, b"{}")
            self.assertEqual(owned_file(path, 2048), b"{}")
            self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)


if __name__ == "__main__":
    unittest.main()
