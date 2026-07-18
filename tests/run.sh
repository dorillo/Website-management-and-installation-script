#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT"

bash -n install.sh lib/*.sh tests/*.sh
bash tests/test_shell.sh

if command -v python3.14 >/dev/null 2>&1; then
    PYTHON=python3.14
elif command -v python3 >/dev/null 2>&1; then
    PYTHON=python3
else
    PYTHON=python
fi

"$PYTHON" -m unittest discover -s tests -p 'test_*.py' -v
"$PYTHON" -m py_compile bin/envctl.py bin/envexec.py

if command -v shellcheck >/dev/null 2>&1; then
    shellcheck install.sh lib/*.sh tests/*.sh
else
    printf 'shellcheck is not installed; lint step skipped.\n' >&2
fi

printf 'All available checks passed.\n'

