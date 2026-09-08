/* Shared runtime value types, kept in their own module so `shell.mts` and
 * `builtins.mts` can both import them without a circular runtime dependency. */

export interface IO {
  out: (s: string) => void;
  err: (s: string) => void;
}

/** A shell variable: a scalar value, or (when `arr` is set) an indexed array.
 *  Coerces to its string value — element 0 for an array, matching bash's `$arr`. */
export class Var {
  value: string;
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
  /** Cached integer value of `value` for arithmetic reads: `iv` is valid only
   *  while `ivStr === value`, so a plain-integer variable in an arith loop is
   *  neither re-parsed nor round-tripped through a string. */
  iv: bigint = 0n;
  ivStr: string | null = null;
  constructor(value: string, exported = false) {
    this.value = value;
    this.exported = exported;
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
