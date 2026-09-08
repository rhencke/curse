# curse

A **bash → TypeScript (`.mts`) converter**. AOT where the structure is static,
JIT (an embedded interpreter over the same AST) where the code is only known at
runtime (`eval`, `source "$x"`, …).

The lexer/parser are ported from GNU bash's `parse.y`, the AST mirrors its
`command.h`, and the conformance suite reuses bash's own tests — so this is a
**GPLv3+** project. See [NOTICE.md](NOTICE.md).

## How it's built

- **Faithful runtime first.** `src/runtime/` is a bash runtime in TypeScript
  (shell state, word expansion, builtins, process plumbing, and — later — the
  AST interpreter). Both `curse run` and the generated `.mts` funnel through the
  same primitives, so their behaviour matches.
- **AOT is a lowering pass on top.** `src/compiler/` turns static structure into
  native TypeScript control flow that calls the runtime.
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
`$(...)`, field splitting on the default IFS, and a handful of builtins
(`echo`, `printf`, `cd`, `pwd`, `export`, `unset`, `:`, `true`, `false`).
Every case passes through both the interpreter and the AOT output, matching
bash on stdout and exit status.

### Roadmap

1. **M1** core language: `if` / `while` / `for` / `case`, `[[ ]]`, `(( ))`, `$(( ))`.
2. **M2** words: full parameter expansion, arrays, globbing, `$@`/`$*`, positionals.
3. **M3** processes: pipelines, redirections/heredocs, subshells, `&` / `wait`,
   more builtins (`read`, `declare`, `local`, `set`, `trap`).
4. **M4** JIT: `eval` / `source "$x"` via the interpreter over the same AST.

Long-term target: point bash's own `tests/run-all` at `curse` as `THIS_SH`.
