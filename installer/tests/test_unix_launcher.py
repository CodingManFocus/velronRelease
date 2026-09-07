"""Exercise launcher boundaries using a fake downloader, without installing Velron."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
RUNNER = ROOT / "installer/unix/run-wizard.sh"


class UnixLauncherTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="velron launcher ' ")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.bin = self.base / "bin"
        self.bin.mkdir()
        self.tmp = self.base / "temporary files"
        self.tmp.mkdir()
        self.marker = self.base / "executed.txt"
        self.env = dict(os.environ, TMPDIR=str(self.tmp), MARKER=str(self.marker))
        self.env["PATH"] = str(self.bin) + os.pathsep + self.env["PATH"]
        # Emulate curl's -o option, including writing a partial body before failing.
        curl = self.bin / "curl"
        curl.write_text("""#!/bin/sh
while [ "$#" -gt 0 ]; do
  if [ "$1" = -o ]; then shift; output=$1; fi
  shift
done
printf '%s' "$MOCK_BODY" > "$output"
exit "$MOCK_DOWNLOAD_STATUS"
""")
        curl.chmod(0o755)

    def invoke(self, body, download_status=0, script=RUNNER):
        env = dict(self.env, MOCK_BODY=body, MOCK_DOWNLOAD_STATUS=str(download_status))
        result = subprocess.run(["sh", str(script)], input="answer\n\n", text=True,
                                capture_output=True, env=env, timeout=10)
        self.assertEqual(list(self.tmp.iterdir()), [], "Temporary download was not removed")
        return result

    def test_success_forwards_input_and_preserves_paths(self):
        result = self.invoke('IFS= read -r answer\nprintf "%s" "$answer" > "$MARKER"\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.marker.read_text(), "answer")
        self.assertIn("Press Enter to close", result.stdout)

    def test_partial_failed_download_does_not_execute(self):
        result = self.invoke('touch "$MARKER"\n', download_status=22)
        self.assertEqual(result.returncode, 22)
        self.assertFalse(self.marker.exists())
        self.assertIn("could not finish", result.stderr)

    def test_empty_download_does_not_report_success(self):
        result = self.invoke("")
        self.assertEqual(result.returncode, 1)
        self.assertIn("empty", result.stderr)

    def test_child_failure_propagates(self):
        result = self.invoke('printf "Wizard failed\\n" >&2\nexit 42\n')
        self.assertEqual(result.returncode, 42)
        self.assertIn("Wizard failed", result.stderr)
        self.assertIn("exit 42", result.stderr)

    def test_linux_terminal_receives_script_as_one_argument(self):
        launch = self.base / "launch.sh"
        shutil.copy(ROOT / "installer/linux/launch.sh", launch)
        shutil.copy(RUNNER, self.base / "run-wizard.sh")
        terminal = self.bin / "x-terminal-emulator"
        terminal.write_text('#!/bin/sh\n[ "$1" = -e ] || exit 90\nshift\nexec "$@"\n')
        terminal.chmod(0o755)
        result = self.invoke('printf done > "$MARKER"\n', script=launch)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.marker.read_text(), "done")

    def test_print_command_has_no_side_effects(self):
        result = subprocess.run(["sh", str(RUNNER), "--print-command"], env=self.env,
                                text=True, capture_output=True, check=True, timeout=10)
        self.assertEqual(result.stdout.strip(),
                         "curl -fsSL https://raw.githubusercontent.com/CodingManFocus/velronRelease/main/install.sh | sh")
        self.assertEqual(list(self.tmp.iterdir()), [])
        self.assertFalse(self.marker.exists())


if __name__ == "__main__":
    unittest.main()
