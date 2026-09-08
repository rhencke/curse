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
