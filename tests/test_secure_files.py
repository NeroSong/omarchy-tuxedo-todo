import importlib.util
import os
from pathlib import Path
import select
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


MODULE_PATH = Path(__file__).resolve().parents[1] / "secure_files.py"
SPEC = importlib.util.spec_from_file_location("secure_files", MODULE_PATH)
secure_files = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(secure_files)


class SecureFilesTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def assert_error(self, code, function, *args):
        with self.assertRaises(secure_files.SecureFileError) as caught:
            function(*args)
        self.assertEqual(code, caught.exception.code)

    def test_normal_todo_read_preserves_bytes(self):
        path = self.root / "todo.txt"
        content = b"first task\nsecond task\n"
        path.write_bytes(content)
        self.assertEqual(content, secure_files.read_todo(str(path)))

    def test_todo_rejects_symlink(self):
        target = self.root / "target"
        target.write_text("task")
        link = self.root / "todo.txt"
        link.symlink_to(target)
        self.assert_error("SYMLINK", secure_files.read_todo, str(link))

    def test_todo_rejects_fifo_without_blocking(self):
        path = self.root / "fifo"
        os.mkfifo(path)
        self.assert_error("NOT_REGULAR", secure_files.read_todo, str(path))

    def test_todo_rejects_directory(self):
        path = self.root / "not-a-file"
        path.mkdir()
        self.assert_error("NOT_REGULAR", secure_files.read_todo, str(path))

    def test_todo_rejects_oversize_file(self):
        path = self.root / "todo.txt"
        with path.open("wb") as stream:
            stream.truncate(secure_files.TODO_MAX_BYTES + 1)
        self.assert_error("TOO_LARGE", secure_files.read_todo, str(path))

    def test_todo_rejects_overlong_line(self):
        path = self.root / "todo.txt"
        path.write_bytes(b"x" * (secure_files.TODO_MAX_LINE_BYTES + 1))
        self.assert_error("LINE_TOO_LONG", secure_files.read_todo, str(path))

    def test_read_detects_growth_between_fstats(self):
        path = self.root / "todo.txt"
        path.write_bytes(b"task\n")
        real_fstat = os.fstat
        calls = 0

        def changed_fstat(fd):
            nonlocal calls
            result = real_fstat(fd)
            calls += 1
            if calls == 2:
                values = list(result)
                values[6] += 1
                return os.stat_result(values)
            return result

        with mock.patch.object(secure_files.os, "fstat", side_effect=changed_fstat):
            self.assert_error("CHANGED", secure_files.read_todo, str(path))

    @unittest.skipUnless(os.geteuid() == 0, "changing ownership requires root")
    def test_todo_rejects_wrong_owner(self):
        path = self.root / "todo.txt"
        path.write_text("task")
        os.chown(path, 1, -1)
        self.assert_error("WRONG_OWNER", secure_files.read_todo, str(path))

    def test_todo_rejects_wrong_owner_via_uid_check(self):
        path = self.root / "todo.txt"
        path.write_text("task")
        with mock.patch.object(secure_files.os, "getuid", return_value=os.getuid() + 1):
            self.assert_error("WRONG_OWNER", secure_files.read_todo, str(path))

    def test_state_round_trip_is_private_and_atomic(self):
        state = self.root / "parent" / "plugin" / "state.json"
        state.parent.parent.mkdir(mode=0o700)
        secure_files.write_state(str(state), b'{"value":1}')
        first_inode = state.stat().st_ino
        self.assertEqual(0o700, stat.S_IMODE(state.parent.stat().st_mode))
        self.assertEqual(0o600, stat.S_IMODE(state.stat().st_mode))
        self.assertEqual(b'{"value":1}', secure_files.read_state(str(state)))
        secure_files.write_state(str(state), b'{"value":2}')
        self.assertNotEqual(first_inode, state.stat().st_ino)
        self.assertEqual(b'{"value":2}', state.read_bytes())
        self.assertEqual([], list(state.parent.glob(".state-*.tmp")))

    def test_state_tightens_owned_directory_mode(self):
        state = self.root / "parent" / "plugin" / "state.json"
        state.parent.mkdir(parents=True, mode=0o755)
        secure_files.write_state(str(state), b"{}")
        self.assertEqual(0o700, stat.S_IMODE(state.parent.stat().st_mode))

    def test_state_rejects_symlink_file(self):
        state = self.root / "parent" / "plugin" / "state.json"
        state.parent.mkdir(parents=True)
        target = self.root / "target"
        target.write_text("{}")
        state.symlink_to(target)
        self.assert_error("SYMLINK", secure_files.write_state, str(state), b"{}")

    def test_state_rejects_symlink_directory(self):
        parent = self.root / "parent"
        target = self.root / "target-dir"
        parent.mkdir()
        target.mkdir()
        (parent / "plugin").symlink_to(target, target_is_directory=True)
        state = parent / "plugin" / "state.json"
        self.assert_error("STATE_DIR_NOT_DIRECTORY", secure_files.write_state, str(state), b"{}")

    def test_state_rejects_broad_file_mode(self):
        state = self.root / "parent" / "plugin" / "state.json"
        state.parent.mkdir(parents=True)
        state.write_text("{}")
        state.chmod(0o644)
        self.assert_error("STATE_FILE_MODE", secure_files.read_state, str(state))

    def test_state_rejects_oversize_content(self):
        state = self.root / "parent" / "plugin" / "state.json"
        state.parent.mkdir(parents=True)
        self.assert_error(
            "TOO_LARGE", secure_files.write_state, str(state), b"x" * (secure_files.STATE_MAX_BYTES + 1)
        )

    @unittest.skipUnless(sys.platform.startswith("linux"), "inotify is Linux-specific")
    def test_watch_detects_atomic_replacement(self):
        watched = self.root / "todo.txt"
        watched.write_text("first\n")
        process = subprocess.Popen(
            [sys.executable, str(MODULE_PATH), "watch", str(watched)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            ready, _, _ = select.select([process.stdout], [], [], 2.0)
            self.assertTrue(ready, "watcher did not become ready")
            self.assertEqual("READY", process.stdout.readline().strip())
            replacement = self.root / ".replacement"
            replacement.write_text("second\n")
            os.replace(replacement, watched)
            ready, _, _ = select.select([process.stdout], [], [], 2.0)
            self.assertTrue(ready, "watcher emitted no event for atomic replacement")
            self.assertEqual("EVENT", process.stdout.readline().strip())
        finally:
            if process.poll() is None:
                process.terminate()
            process.wait(timeout=2)
            process.stdout.close()
            process.stderr.close()


if __name__ == "__main__":
    unittest.main()
