"""The package pins its version in one place."""

import lamidos


def test_version_is_pinned():
    assert lamidos.__version__ == "0.1.0"
