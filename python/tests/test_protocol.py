"""Conformance tests driven by fixtures/protocol.json.

Cases are loaded from the shared, language-neutral fixture file rather
than hand-copied, per the CONTRACT's testing requirements.
"""

import json
from pathlib import Path

import pytest

from sprite_direct.protocol import SpriteEvalError, decode, encode, parse_response
from sprite_direct.sexp import Quote, Sym, print_sexp

FIXTURE_PATH = Path(__file__).resolve().parents[2] / "fixtures" / "protocol.json"


@pytest.fixture(scope="module")
def fixtures():
    with open(FIXTURE_PATH, "r", encoding="utf-8") as fh:
        return json.load(fh)


# ---------------------------------------------------------------------------
# encode_decode
# ---------------------------------------------------------------------------


def test_encode_decode_cases(fixtures):
    cases = fixtures["encode_decode"]["cases"]
    assert cases, "expected at least one encode_decode case"
    for case in cases:
        decoded, encoded = case["decoded"], case["encoded"]
        assert encode(decoded) == encoded, f"encode({decoded!r})"
        assert decode(encoded) == decoded, f"decode({encoded!r})"


# ---------------------------------------------------------------------------
# sexp_print
# ---------------------------------------------------------------------------


def _build_form(node):
    node_type = node["type"]
    value = node["value"]
    if node_type == "sym":
        return Sym(value)
    if node_type == "str":
        return value
    if node_type == "int":
        return int(value)
    if node_type == "float":
        return float(value)
    if node_type == "list":
        return [_build_form(item) for item in value]
    if node_type == "quote":
        return Quote(_build_form(value))
    raise ValueError(f"unknown fixture node type: {node_type!r}")


def test_sexp_print_cases(fixtures):
    cases = fixtures["sexp_print"]["cases"]
    assert cases, "expected at least one sexp_print case"
    for case in cases:
        form = _build_form(case["form"])
        assert print_sexp(form) == case["printed"]


# ---------------------------------------------------------------------------
# response_reassembly
# ---------------------------------------------------------------------------


def test_response_reassembly_cases(fixtures):
    cases = fixtures["response_reassembly"]["cases"]
    assert cases, "expected at least one response_reassembly case"
    for case in cases:
        raw = ("\n".join(case["raw_lines"]) + "\n").encode("utf-8")
        expected = case["expected"]
        status = expected["status"]

        if status == "ok":
            assert parse_response(raw) == expected["value"], case["name"]
        elif status == "error":
            with pytest.raises(SpriteEvalError) as excinfo:
                parse_response(raw)
            assert str(excinfo.value) == expected["message"], case["name"]
        elif status == "empty":
            assert parse_response(raw) is None, case["name"]
        else:
            raise ValueError(f"unknown expected status: {status!r}")
