/* Shared runtime value types, kept in their own module so `shell.mts` and
 * `builtins.mts` can both import them without a circular runtime dependency. */

export interface IO {
  out: (s: string) => void;
  err: (s: string) => void;
}

/** A shell variable: a scalar value, or (when `arr` is set) an indexed array.
 *  Coerces to its string value — element 0 for an array, matching bash's `$arr`. */
export class Var {
  exported: boolean;
  /** Indexed-array elements (sparse), or null. */
  arr: Map<number, string> | null = null;
  /** Associative-array elements (declare -A), or null. */
  assoc: Map<string, string> | null = null;
  /** Attributes: -i evaluates arithmetic on assignment; -l/-u force case. */
  integer = false;
  lower = false;
  upper = false;
  readonly = false;
  /** declare -n: a nameref whose `value` holds the target variable's name. */
  ref = false;
  /** Declared but unset (e.g. `local x`): occupies scope for shadowing, but
   *  reads as unset until a value is assigned. */
  unset = false;

  // Lazy value: a scalar's value is kept as a string (`_str`) or, after an
  // arithmetic write, as a BigInt (`_iv` with `_fresh`) whose string form is
  // only materialized when a string context reads it. `_ivStr` additionally
  // caches the parse of a plain string value, so an arith loop neither
  // re-parses nor round-trips its counter through a string each iteration.
  private _str: string;
  private _iv: bigint = 0n;
  private _fresh = false;
  private _ivStr: string | null = null;

  constructor(value: string, exported = false) {
    this._str = value;
    this.exported = exported;
  }

  get value(): string {
    if (this._fresh) {
      this._str = this._iv.toString();
      this._ivStr = this._str;
      this._fresh = false;
    }
    return this._str;
  }
  set value(s: string) {
    this._str = s;
    this._fresh = false;
    this._ivStr = null;
  }

  /** Arithmetic read: the cached integer when the current value is a fresh int
   *  or a string whose parse we remembered, else null (the caller parses). */
  intCache(): bigint | null {
    if (this._fresh) return this._iv;
    return this._ivStr !== null && this._ivStr === this._str ? this._iv : null;
  }
  /** Remember that string `s` parsed to integer `v` (arith read cache). */
  cacheInt(s: string, v: bigint): void {
    this._iv = v;
    this._ivStr = s;
  }
  /** Arithmetic write: store the integer and defer its string form. */
  setInt(v: bigint): void {
    this._iv = v;
    this._fresh = true;
  }

  scalar(): string {
    if (this.assoc !== null) return this.assoc.get("0") ?? "";
    return this.arr !== null ? this.arr.get(0) ?? "" : this.value;
  }
  toString(): string {
    return this.scalar();
  }
  valueOf(): string {
    return this.scalar();
  }
}

/** Thrown by the `return` builtin, caught at the function-call boundary. */
export class ReturnSignal {
  code: number;
  constructor(code: number) {
    this.code = code;
  }
}

/** Thrown by the `exit` builtin, caught at the shell/subshell boundary. */
export class ExitSignal {
  code: number;
  constructor(code: number) {
    this.code = code;
  }
}

/** Thrown by `break`/`continue`; a loop consumes one level, rethrowing while
 *  `count` (break N / continue N) remains above 1. */
export class LoopSignal {
  kind: "break" | "continue";
  count: number;
  constructor(kind: "break" | "continue", count: number) {
    this.kind = kind;
    this.count = count;
  }
}
