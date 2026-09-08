/* Shared runtime value types, kept in their own module so `shell.mts` and
 * `builtins.mts` can both import them without a circular runtime dependency. */

export interface IO {
  out: (s: string) => void;
  err: (s: string) => void;
}

/** A shell variable: a value plus attributes. Coerces to its string value. */
export class Var {
  value: string;
  exported: boolean;
  constructor(value: string, exported = false) {
    this.value = value;
    this.exported = exported;
  }
  toString(): string {
    return this.value;
  }
  valueOf(): string {
    return this.value;
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
