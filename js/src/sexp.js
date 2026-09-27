/**
 * Tagged S-expression builder and Lisp-syntax printer.
 *
 * Build forms with the constructors below and print them to Lisp reader
 * syntax with printSexp(). This printing step is independent of, and
 * happens *before*, the wire-protocol encode/decode in protocol.js — the
 * pipeline is:
 *
 *     build form -> printSexp(form) -> encode(text) -> send over wire
 */

/**
 * A symbol: a String subclass that prints bare (unquoted), as opposed to
 * a plain JS string which prints quoted.
 */
export class Sym extends String {}

/** Construct a symbol form. */
export function sym(name) {
  return new Sym(name);
}

/** Wraps a form so it prints as `(quote form)`. */
export class Quote {
  constructor(form) {
    this.form = form;
  }
}

/** Construct a quoted form: prints as `(quote form)`. */
export function quote(form) {
  return new Quote(form);
}

/**
 * Wraps a JS number to force printing as a Lisp float (e.g. "2.0", not
 * "2"). Plain JS numbers have no int/float distinction (`1.0 === 1`),
 * so a whole-number value passed as a bare `number` always prints
 * without a decimal point; wrap it in `Float` when the callee expects
 * a float and the value happens to be a whole number.
 */
export class Float {
  constructor(value) {
    this.value = value;
  }
}

/** Construct a float form that always prints with a decimal point. */
export function float(value) {
  return new Float(value);
}

/** Escape a JS string Lisp-prin1-style: backslash and quote only. */
function escapeString(value) {
  let out = "";
  for (const ch of value) {
    if (ch === "\\") {
      out += "\\\\";
    } else if (ch === '"') {
      out += '\\"';
    } else {
      out += ch;
    }
  }
  return out;
}

/**
 * Print a tagged form to Lisp reader syntax (no wire encoding).
 *
 * Supported forms:
 *   - Sym: printed bare
 *   - Quote: printed as `(quote form)`
 *   - Float: printed with a guaranteed decimal point
 *   - string: printed quoted, with escaping
 *   - number: printed via String() (prints without a decimal point for
 *     whole numbers — wrap in Float if the callee expects a float)
 *   - Array: printed as a parenthesized list
 */
export function printSexp(form) {
  if (form instanceof Sym) {
    return form.toString();
  }
  if (form instanceof Quote) {
    return `(quote ${printSexp(form.form)})`;
  }
  if (form instanceof Float) {
    const s = String(form.value);
    return /[.eE]/.test(s) ? s : `${s}.0`;
  }
  if (typeof form === "string") {
    return `"${escapeString(form)}"`;
  }
  if (typeof form === "number") {
    return String(form);
  }
  if (Array.isArray(form)) {
    return "(" + form.map(printSexp).join(" ") + ")";
  }
  throw new TypeError(`unsupported sexp form: ${String(form)}`);
}
