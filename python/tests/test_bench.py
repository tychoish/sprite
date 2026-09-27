"""Native Python micro-benchmarks for eval_blocking against a real
`emacs --daemon`, using pytest-benchmark rather than a shared
cross-language driver -- these numbers are for tracking this
language's own per-call cost over time, not for a cross-language
latency comparison.

Requires the optional `bench` extra: `pip install -e '.[bench]'`.
Gated on SPRITE_TEST_SOCKET, same convention as test_integration.py.
Run with:

    SPRITE_TEST_SOCKET=/path/to/socket pytest tests/test_bench.py --benchmark-only -v
"""

import os
import subprocess

import pytest

from sprite_direct.conn import eval_blocking
from sprite_direct.sexp import sym

pytest.importorskip("pytest_benchmark")

SOCKET = os.environ.get("SPRITE_TEST_SOCKET")

pytestmark = pytest.mark.skipif(
    not SOCKET, reason="SPRITE_TEST_SOCKET not set; skipping benchmark"
)

FORMS = {
    "small-int": [sym("+"), 1, 2],
    "large-string": [sym("make-string"), 5000, 120],
}

RAW_FORMS = {
    "small-int": "(+ 1 2)",
    "large-string": "(make-string 5000 120)",
}


@pytest.mark.parametrize("name", FORMS.keys())
def test_eval_blocking(benchmark, name):
    form = FORMS[name]
    benchmark(lambda: eval_blocking(SOCKET, form, timeout=5))


@pytest.mark.parametrize("name", RAW_FORMS.keys())
def test_emacsclient_subprocess(benchmark, name):
    if subprocess.run(["which", "emacsclient"], capture_output=True).returncode != 0:
        pytest.skip("emacsclient binary not found on PATH; skipping benchmark")
    form = RAW_FORMS[name]
    benchmark(
        lambda: subprocess.run(
            ["emacsclient", f"--socket-name={SOCKET}", "--eval", form],
            check=True,
            capture_output=True,
        )
    )
