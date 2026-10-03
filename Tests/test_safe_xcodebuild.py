import importlib.util
import os
from pathlib import Path
import stat
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "safe-xcodebuild.py"
SPEC = importlib.util.spec_from_file_location("safe_xcodebuild", SCRIPT)
safe_xcodebuild = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(safe_xcodebuild)


class FakeChild:
    def __init__(self, lines):
        self.stdout = iter(lines)
        self.returncode = 7

    def wait(self):
        return self.returncode


class SafeXcodebuildTests(unittest.TestCase):
    def test_child_gets_no_inherited_secret_and_log_is_private(self):
        captured = {}

        def fake_popen(argv, **kwargs):
            captured.update(argv=argv, env=kwargs["env"])
            return FakeChild(["BUILD_SECRET='sentinel with spaces'\n", "diagnostic\n"])

        with tempfile.TemporaryDirectory(dir=Path(__file__).resolve().parents[1] / ".local") as directory:
            log = Path(directory) / "build.log"
            old = os.environ.get("BUILD_SECRET")
            os.environ["BUILD_SECRET"] = "sentinel"
            try:
                result = safe_xcodebuild.run_xcodebuild(
                    ["-scheme", "recall"], log, popen_factory=fake_popen
                )
            finally:
                if old is None:
                    os.environ.pop("BUILD_SECRET", None)
                else:
                    os.environ["BUILD_SECRET"] = old
            self.assertEqual(result, (7, 2, 1))
            self.assertNotIn("BUILD_SECRET", captured["env"])
            self.assertNotIn("sentinel", log.read_text())
            self.assertEqual(stat.S_IMODE(log.stat().st_mode), 0o600)
            self.assertEqual(captured["argv"][0], safe_xcodebuild.XCODEBUILD)

    def test_environment_is_fixed_and_does_not_copy_arbitrary_values(self):
        env = safe_xcodebuild.minimal_environment(
            {"HOME": "/home/test", "TMPDIR": "/tmp/test", "DEVELOPER_DIR": "/xcode", "TOKEN": "secret"}
        )
        self.assertEqual(env, {"PATH": safe_xcodebuild.FIXED_PATH, "HOME": "/home/test", "TMPDIR": "/tmp/test", "DEVELOPER_DIR": "/xcode"})

    def test_argument_errors_are_safe(self):
        with self.assertRaises(ValueError):
            safe_xcodebuild._parse(["--log", "only-log"])
        with self.assertRaises(ValueError):
            safe_xcodebuild._parse(["--log", "", "--", "build"])

    def test_invalid_log_path_does_not_start_child(self):
        started = []

        def fake_popen(*args, **kwargs):
            started.append(True)
            return FakeChild([])

        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(ValueError):
                safe_xcodebuild.run_xcodebuild(["build"], Path(directory) / "build.log", popen_factory=fake_popen)
        self.assertEqual(started, [])


if __name__ == "__main__":
    unittest.main()
