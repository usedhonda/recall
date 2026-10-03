#!/usr/bin/env python3
"""Run xcodebuild without inheriting or printing the caller's environment.

The log path is explicit and is opened with mode 0600.  Only a fixed PATH and
the process's HOME, TMPDIR, and DEVELOPER_DIR (when present) are passed to the
child.  Child output is streamed through a small assignment redactor before it
is written to the private log; stdout contains only bounded status counters.
"""

from __future__ import annotations

import os
from pathlib import Path
import re
import subprocess
import sys
from typing import Callable, Iterable, Mapping, Sequence


XCODEBUILD = "/usr/bin/xcodebuild"
FIXED_PATH = "/usr/bin:/bin:/usr/sbin:/sbin"
_ASSIGNMENT = re.compile(r"(?:^|[\s;])([A-Za-z_][A-Za-z0-9_]*)=(?:'[^']*'|\"[^\"]*\"|[^\s]+)")


def minimal_environment(source: Mapping[str, str] | None = None) -> dict[str, str]:
    """Return the intentionally tiny environment supplied to xcodebuild."""

    source = os.environ if source is None else source
    result = {"PATH": FIXED_PATH}
    for key in ("HOME", "TMPDIR", "DEVELOPER_DIR"):
        value = source.get(key)
        if value:
            result[key] = value
    return result


def redact_assignments(line: str) -> tuple[str, int]:
    """Drop lines that could contain an environment assignment or env dump."""

    matches = _ASSIGNMENT.findall(line)
    if matches or re.search(r"(?:^|[\s;])env\s+-i(?:[\s;]|$)", line):
        return "[environment assignment output omitted]\n", max(1, len(matches))
    return line, 0


def _open_private_log(path: Path):
    root = Path(__file__).resolve().parents[1]
    allowed_roots = (root / ".local", root / "docs" / "log" / "codex")
    candidate = path if path.is_absolute() else Path.cwd() / path
    raw_parent = candidate.absolute().parent
    current = raw_parent
    while current != current.parent:
        if current.is_symlink():
            raise ValueError("invalid log path")
        current = current.parent
    resolved = candidate.resolve(strict=False)
    if not any(resolved == allowed or allowed in resolved.parents for allowed in allowed_roots):
        raise ValueError("invalid log path")
    if candidate.exists() and candidate.is_symlink():
        raise ValueError("invalid log path")
    if not candidate.parent.is_dir():
        raise ValueError("invalid log path")
    flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    fd = os.open(candidate, flags, 0o600)
    os.fchmod(fd, 0o600)
    return os.fdopen(fd, "w", encoding="utf-8", errors="replace")


def run_xcodebuild(
    xcode_args: Sequence[str],
    log_path: Path,
    *,
    environ: Mapping[str, str] | None = None,
    popen_factory: Callable[..., object] = subprocess.Popen,
) -> tuple[int, int, int]:
    """Run a build and return ``(exit_code, line_count, redaction_count)``."""

    if not xcode_args or any(not isinstance(arg, str) for arg in xcode_args):
        raise ValueError("xcodebuild arguments required")
    lines = 0
    redactions = 0
    # Validate/open the destination before starting xcodebuild: a build must
    # never run without its required private capture path.
    with _open_private_log(log_path) as log:
        child = popen_factory(
            [XCODEBUILD, *xcode_args],
            env=minimal_environment(environ),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )
        output: Iterable[str] = getattr(child, "stdout", ()) or ()
        for line in output:
            safe, count = redact_assignments(line)
            log.write(safe)
            lines += 1
            redactions += count
        return_code = child.wait()
    return int(return_code), lines, redactions


def _parse(argv: Sequence[str]) -> tuple[Path, list[str]]:
    if len(argv) < 3 or argv[0] != "--log":
        raise ValueError("usage")
    log_path = Path(argv[1])
    xcode_args = list(argv[2:])
    if xcode_args and xcode_args[0] == "--":
        xcode_args.pop(0)
    if not xcode_args or log_path.name in ("", ".", ".."):
        raise ValueError("usage")
    return log_path, xcode_args


def main(argv: Sequence[str] | None = None) -> int:
    try:
        log_path, xcode_args = _parse(sys.argv[1:] if argv is None else argv)
        code, lines, redactions = run_xcodebuild(xcode_args, log_path)
    except ValueError:
        print("usage: safe-xcodebuild.py --log PRIVATE_LOG [--] XCODEBUILD_ARGS", file=sys.stderr)
        return 2
    except OSError:
        print("xcodebuild failed to start or private log could not be opened", file=sys.stderr)
        return 1
    print(f"xcodebuild exit={code} lines={lines} redactions={redactions}")
    return code


if __name__ == "__main__":
    raise SystemExit(main())
