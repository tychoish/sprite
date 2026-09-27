//! Fixture-driven conformance tests.
//!
//! Loads `../fixtures/protocol.json` (the shared, language-neutral
//! conformance fixtures — see `fixtures/CONTRACT.md`) and iterates its
//! three sections rather than hand-copying cases, so a fixed protocol
//! bug in the fixture data is caught here too.
//!
//! `serde`/`serde_json` are dev-dependencies only, used here to parse
//! the fixture file; they are not part of the shipped library surface.

use serde::Deserialize;
use serde_json::Value;
use std::path::PathBuf;

use sprite_direct::protocol::{decode, encode, parse_response};
use sprite_direct::sexp::{print_sexp, Sexp};
use sprite_direct::SpriteError;

#[derive(Deserialize)]
struct Fixtures {
    encode_decode: EncodeDecodeSection,
    sexp_print: SexpPrintSection,
    response_reassembly: ResponseReassemblySection,
}

#[derive(Deserialize)]
struct EncodeDecodeSection {
    cases: Vec<EncodeDecodeCase>,
}

#[derive(Deserialize)]
struct EncodeDecodeCase {
    decoded: String,
    encoded: String,
}

#[derive(Deserialize)]
struct SexpPrintSection {
    cases: Vec<SexpPrintCase>,
}

#[derive(Deserialize)]
struct SexpPrintCase {
    form: FormNode,
    printed: String,
}

#[derive(Deserialize)]
struct FormNode {
    #[serde(rename = "type")]
    kind: String,
    value: Value,
}

#[derive(Deserialize)]
struct ResponseReassemblySection {
    cases: Vec<ResponseReassemblyCase>,
}

#[derive(Deserialize)]
struct ResponseReassemblyCase {
    name: String,
    raw_lines: Vec<String>,
    expected: ExpectedOutcome,
}

#[derive(Deserialize)]
struct ExpectedOutcome {
    status: String,
    value: Option<String>,
    message: Option<String>,
}

fn load_fixtures() -> Fixtures {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../fixtures/protocol.json");
    let raw = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("failed to read fixtures at {path:?}: {e}"));
    serde_json::from_str(&raw).expect("failed to parse fixtures/protocol.json")
}

fn form_to_sexp(node: &FormNode) -> Sexp {
    match node.kind.as_str() {
        "sym" => Sexp::Sym(node.value.as_str().unwrap().to_string()),
        "str" => Sexp::Str(node.value.as_str().unwrap().to_string()),
        "int" => Sexp::Int(node.value.as_i64().unwrap()),
        "float" => Sexp::Float(node.value.as_f64().unwrap()),
        "list" => {
            let items: Vec<FormNode> =
                serde_json::from_value(node.value.clone()).expect("list value must be an array");
            Sexp::List(items.iter().map(form_to_sexp).collect())
        }
        "quote" => {
            let inner: FormNode =
                serde_json::from_value(node.value.clone()).expect("quote value must be a form");
            sprite_direct::sexp::quote(form_to_sexp(&inner))
        }
        other => panic!("unknown form type: {other}"),
    }
}

#[test]
fn encode_decode_fixtures() {
    let fixtures = load_fixtures();
    for case in fixtures.encode_decode.cases {
        assert_eq!(
            encode(&case.decoded),
            case.encoded,
            "encode({:?})",
            case.decoded
        );
        assert_eq!(
            decode(&case.encoded),
            case.decoded,
            "decode({:?})",
            case.encoded
        );
    }
}

#[test]
fn sexp_print_fixtures() {
    let fixtures = load_fixtures();
    for case in fixtures.sexp_print.cases {
        let sexp = form_to_sexp(&case.form);
        assert_eq!(print_sexp(&sexp), case.printed);
    }
}

#[test]
fn response_reassembly_fixtures() {
    let fixtures = load_fixtures();
    for case in fixtures.response_reassembly.cases {
        let raw = case.raw_lines.join("\n");
        let result = parse_response(&raw);
        match case.expected.status.as_str() {
            "ok" => {
                let expected_value = case
                    .expected
                    .value
                    .unwrap_or_else(|| panic!("case {:?}: missing expected value", case.name));
                assert_eq!(
                    result.expect("expected Ok result"),
                    expected_value,
                    "case: {}",
                    case.name
                );
            }
            "error" => {
                let expected_message = case
                    .expected
                    .message
                    .unwrap_or_else(|| panic!("case {:?}: missing expected message", case.name));
                match result {
                    Err(SpriteError::Eval(msg)) => {
                        assert_eq!(msg, expected_message, "case: {}", case.name)
                    }
                    other => panic!("case {}: expected Eval error, got {other:?}", case.name),
                }
            }
            "empty" => match result {
                Err(SpriteError::Empty) => {}
                other => panic!("case {}: expected Empty error, got {other:?}", case.name),
            },
            other => panic!("unknown expected status: {other}"),
        }
    }
}
