# curse

A **bash → TypeScript (`.mts`) converter**. AOT where the structure is static,
JIT (an embedded interpreter over the same AST) where the code is only known at
runtime (`eval`, `source "$x"`, …).

The lexer/parser are ported from GNU bash's `parse.y`, the AST mirrors its
`command.h`, and the conformance suite reuses bash's own tests — so this is a
**GPLv3+** project. See [NOTICE.md](NOTICE.md).

## How it's built

**Compiler first, interpreter only where bash forces it.** The AOT path emits
real TypeScript that leans on JavaScript's own dynamism to model bash's:

- **Commands are live bindings.** `sh.commands` is a `Proxy` whose prototype is
  the builtins; a bash function compiles to `sh.commands.name = sh.func(...)`,
  which *monkeypatches* the binding (and `unset -f` reveals the builtin again).
  Unknown names fall through to external processes. Dispatch is a property
  lookup, not a string switch.
- **Assignment is property mutation:** `sh.env.name = \`world\``, with
  `sh.env.name.exported = true` when needed. `sh.env` is a Proxy over a
  **prototype-linked scope chain** — which is also exactly how `local` and
  bash's dynamic scoping fall out (`Object.create(callerScope)`).
- **Expansion compiles inline:** template literals for `"$x"`, `sh.fields`/`sh.S`
  for word splitting, inline `sh.sub(async sh => …)` for `$(...)`. No raw bash
  strings survive into the output.
- **Control flow becomes native TS** (`if`, `for…of`, `for(;;)`); `sh.status`
  carries `$?`.

The interpreter (`src/runtime/shell.mts` `execute`) drives the *same* surface —
`sh.commands`, `sh.env`, builtins — so it is the JIT/eval path (compile a string
at runtime) and stays behaviourally identical to the compiled output.

- **Async/await throughout** so pipelines, `&`, and streaming are correct.
- **Zero-build.** Node 24's type-stripping runs the `.mts` sources *and* the
  generated output directly — `tsc` (v7) is only a type checker.

## Dev environment

Everything runs in the `curse-dev` image (Node 24 + bash 5.2.37). Build it once:

```sh
make build         # create the buildx builder + build/load curse-dev:latest
```

Then use `./x` to run any command inside it (repo mounted, your uid):

```sh
./x npm install          # install devDeps (@types/node, typescript@7)
./x npm run typecheck    # tsc --noEmit   (validate types)
./x npm test             # node --test    (conformance vs real bash)
./x npm run check        # typecheck, then test

./x node ./src/cli/curse.mts run       test/cases/030-and-or.sh
./x node ./src/cli/curse.mts transpile test/cases/030-and-or.sh
./x node ./src/cli/curse.mts parse     test/cases/030-and-or.sh
```

## Layout

```
src/
  ast/       AST node types (mirror bash command.h)
  parser/    lexer + recursive-descent parser (ported from parse.y)
  runtime/   Shell state, expansion engine, builtins, process spawning
  compiler/  AOT emitter (AST -> .mts)
  cli/       the `curse` CLI
test/
  cases/       small bash scripts exercising current features
  conformance/ node:test harness: interp + AOT vs real bash
reference/bash/ upstream bash 5.2.37 (gitignored) — porting source + test suite
```

## Status

**M0 — foundation (done).** Simple commands, `;` / `&&` / `||`, assignments,
`$var` / `${var}` / `$?`, single/double quotes + escapes, command substitution
`$(...)`, field splitting on the default IFS, and core builtins (`echo`,
`printf`, `cd`, `pwd`, `export`, `unset`, `:`, `true`, `false`).

**M1 — control flow + arithmetic (mostly done).** `if`/`elif`/`else`,
`while`/`until`, `for` (list form and C-style `for ((;;))`), subshells `( )`,
groups `{ }`, `!` negation, the `(( ))` command and `$(( ))` expansion (a
64-bit BigInt evaluator with C precedence and recursive variable resolution),
and the `test` / `[` builtin. Still open in M1: `case`/`esac` and `[[ ]]`.

**Functions + scope (done).** `name() { … }` and `function name`, positional
parameters (`$1`, `$#`, `$@`, `$*`), `local`, `return`, dynamic scoping, and
redefining commands/builtins (monkeypatch) — all via the command-registry and
scope model above.

Every case passes through **both** the interpreter and the AOT output, matching
bash on stdout and exit status.

### Roadmap

1. **M1 remainder**: `case`/`esac`, `[[ ]]`.
2. **M2** words: full parameter expansion (`${x:-y}`, `${x#p}`, …), arrays,
   globbing, `$@`/`$*`, positional parameters, tilde/brace expansion.
3. **M3** processes: pipelines, redirections/heredocs, `&` / `wait`, and more
   builtins (`read`, `declare`, `set`, `trap`, `shift`, `command`/`builtin`).
4. **M4** JIT: `eval` / `source "$x"` via the interpreter over the same AST.

Long-term target: point bash's own `tests/run-all` at `curse` as `THIS_SH`.
