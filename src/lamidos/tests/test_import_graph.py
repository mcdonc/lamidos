"""Pin the import-graph invariants inside the suite.

The commit hook and lamidos-preflight run the two walkers over the
tree; this test runs the same scripts so a config/code drift that
slips past a --no-verify commit still fails the suite.
"""

import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]

WALKERS = [
    "scripts/check_import_cycles.py",
    "scripts/check_import_graph.py",
]


def run_walker(script: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, str(REPO_ROOT / script)],
        capture_output=True,
        text=True,
        check=False,
    )


def test_import_walkers_are_green():
    for script in WALKERS:
        result = run_walker(script)
        assert result.returncode == 0, (
            f"{script} failed:\n{result.stdout}{result.stderr}"
        )
