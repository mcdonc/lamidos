"""Pin the coverage engine for every suite run."""

import os

# Use the sysmon coverage engine — on Python 3.14 sys.monitoring
# measures branches natively, which is why CI runs with `-n auto`
# (a single-process run under-counts and shows a false low total;
# see AGENTS.md). No `concurrency` option anywhere: sysmon does
# not support it.
os.environ.setdefault("COVERAGE_CORE", "sysmon")
