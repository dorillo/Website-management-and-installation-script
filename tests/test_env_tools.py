from __future__ import annotations

import importlib.util
import io
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]


def load_module(name: str, relative_path: str):
    specification = importlib.util.spec_from_file_location(name, ROOT / relative_path)
    assert specification is not None and specification.loader is not None
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


envctl = load_module("envctl_under_test", "bin/envctl.py")
envexec = load_module("envexec_under_test", "bin/envexec.py")


class EnvctlTests(unittest.TestCase):
    def make_file(self, directory: str, content: str) -> Path:
        path = Path(directory) / "app.env"
        path.write_text(content, encoding="utf-8", newline="\n")
        return path

    def test_parse_preserves_comments_and_literal_values(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = self.make_file(
                directory, "# comment\nEMPTY=\nJSON={}\nLITERAL=$HOME;echo nope\n"
            )
            self.assertEqual(
                envctl.parse(path),
                [
                    (None, "# comment"),
                    ("EMPTY", ""),
                    ("JSON", "{}"),
                    ("LITERAL", "$HOME;echo nope"),
                ],
            )

    def test_parse_rejects_duplicate_keys(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = self.make_file(directory, "A=one\nA=two\n")
            with self.assertRaisesRegex(ValueError, "duplicate variable A"):
                envctl.parse(path)

    def test_set_is_atomic_and_preserves_file_mode(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = self.make_file(directory, "# comment\nA=old\n")
            os.chmod(path, 0o640)
            chown = getattr(os, "chown", None)
            chown_patch = mock.patch.object(os, "chown", create=True) if chown is None else mock.patch.object(os, "chown")
            with chown_patch, mock.patch.object(sys, "stdin", io.StringIO("new=value")):
                self.assertEqual(envctl.command_set(path, "A"), 0)
            self.assertEqual(path.read_text(encoding="utf-8"), "# comment\nA=new=value\n")
            if os.name == "posix":
                self.assertEqual(path.stat().st_mode & 0o777, 0o640)

    def test_set_rejects_surrounding_spaces(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = self.make_file(directory, "A=old\n")
            with mock.patch.object(sys, "stdin", io.StringIO(" value")):
                with self.assertRaisesRegex(ValueError, "spaces are forbidden"):
                    envctl.command_set(path, "A")


class EnvexecTests(unittest.TestCase):
    def run_main(self, content: str) -> tuple[list[str], dict[str, str]]:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "app.env"
            path.write_text(content, encoding="utf-8", newline="\n")
            captured: dict[str, object] = {}

            def fake_exec(file: str, arguments: list[str], environment: dict[str, str]) -> None:
                captured["file"] = file
                captured["arguments"] = arguments
                captured["environment"] = environment

            argv = ["envexec.py", str(path), "command", "argument"]
            with mock.patch.object(sys, "argv", argv), mock.patch.object(
                envexec.os, "execvpe", side_effect=fake_exec
            ):
                envexec.main()
            return captured["arguments"], captured["environment"]  # type: ignore[return-value]

    def test_exec_uses_values_literally(self) -> None:
        arguments, environment = self.run_main("A=$HOME;echo nope\nEMPTY=\n")
        self.assertEqual(arguments, ["command", "argument"])
        self.assertEqual(environment["A"], "$HOME;echo nope")
        self.assertEqual(environment["EMPTY"], "")

    def test_exec_rejects_duplicate_keys(self) -> None:
        with mock.patch.object(sys, "stderr", io.StringIO()):
            with self.assertRaisesRegex(SystemExit, "2"):
                self.run_main("A=one\nA=two\n")

    def test_exec_rejects_invalid_line(self) -> None:
        with mock.patch.object(sys, "stderr", io.StringIO()):
            with self.assertRaisesRegex(SystemExit, "2"):
                self.run_main("not-an-assignment\n")


if __name__ == "__main__":
    unittest.main()
