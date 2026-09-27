//! S-expression builder and printer.
//!
//! Tagged-union representation of Lisp forms (symbol, string, int, float,
//! list, quote) and a printer that produces `prin1`-style Lisp reader
//! syntax. This printing step is independent of, and happens *before*,
//! the wire-protocol encode step in [`crate::protocol`]: build a form,
//! print it to text, then wire-encode that text.

/// A tagged-union Lisp form.
#[derive(Debug, Clone, PartialEq)]
pub enum Sexp {
    /// A bare symbol, printed verbatim (e.g. `foo`, `+`).
    Sym(String),
    /// A string, printed with `prin1`-style escaping of `\` and `"`.
    Str(String),
    /// An integer.
    Int(i64),
    /// A floating point number.
    Float(f64),
    /// A variadic list, printed as `(a b c)`.
    List(Vec<Sexp>),
}

/// Wrap `form` as `(quote form)`.
///
/// There is no separate `Quote` variant; quoting is just a list whose
/// head is the symbol `quote`, matching the CONTRACT's note that
/// function-call forms are lists whose head is a symbol with no
/// separate "call" constructor.
pub fn quote(form: Sexp) -> Sexp {
    Sexp::List(vec![Sexp::Sym("quote".to_string()), form])
}

/// Print `form` to Lisp reader syntax (`prin1`-style).
///
/// String printing escapes `\` and `"`. This is the printed
/// representation that gets wire-encoded before being sent to the
/// server; it does not itself apply wire-protocol quoting.
pub fn print_sexp(form: &Sexp) -> String {
    let mut out = String::new();
    print_into(form, &mut out);
    out
}

fn print_into(form: &Sexp, out: &mut String) {
    match form {
        Sexp::Sym(s) => out.push_str(s),
        Sexp::Str(s) => {
            out.push('"');
            for c in s.chars() {
                match c {
                    '\\' => out.push_str("\\\\"),
                    '"' => out.push_str("\\\""),
                    _ => out.push(c),
                }
            }
            out.push('"');
        }
        Sexp::Int(i) => out.push_str(&i.to_string()),
        Sexp::Float(f) => out.push_str(&format_float(*f)),
        Sexp::List(items) => {
            out.push('(');
            for (i, item) in items.iter().enumerate() {
                if i > 0 {
                    out.push(' ');
                }
                print_into(item, out);
            }
            out.push(')');
        }
    }
}

/// Format a float the way Emacs Lisp's printer does for simple cases:
/// always include a decimal point (e.g. `1.5`, `1.0`).
fn format_float(f: f64) -> String {
    let s = f.to_string();
    if s.contains('.') || s.contains('e') || s.contains('E') {
        s
    } else {
        format!("{s}.0")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prints_symbol() {
        assert_eq!(print_sexp(&Sexp::Sym("+".to_string())), "+");
    }

    #[test]
    fn prints_negative_int() {
        assert_eq!(print_sexp(&Sexp::Int(-3)), "-3");
    }

    #[test]
    fn prints_quote() {
        assert_eq!(
            print_sexp(&quote(Sexp::Sym("foo".to_string()))),
            "(quote foo)"
        );
    }

    #[test]
    fn escapes_string() {
        assert_eq!(
            print_sexp(&Sexp::Str("say \"hi\"\\".to_string())),
            "\"say \\\"hi\\\"\\\\\""
        );
    }
}
