# Attribution

`curse` is a bash-compatible shell implemented in LuaJIT. It is licensed under
the **GNU General Public License v3.0 or later** (see [LICENSE](LICENSE)).

## Derived from GNU Bash

Portions of this project are derived from **GNU Bash 5.2.37**
(<https://ftp.gnu.org/gnu/bash/>), Copyright (C) the Free Software
Foundation, Inc., licensed under GPLv3+.

Specifically:

- **The parser and its AST** (`lua/parser.lua`) are ported from bash's `parse.y`
  and mirror the command structures in bash's `command.h`.
- **The word-expansion and variable engine** (`lua/runtime.lua`) follows the
  algorithms in bash's `subst.c` and `variables.c`.

Conformance is verified by running curse against **real bash** as the oracle
(`test/cases/`, and the Oils spec runner below); no bash expectation files are
vendored.

Because this project is a derivative work of GNU Bash, it is distributed
under the same GPLv3+ license. The upstream bash source is kept locally in
`reference/bash/` (gitignored) and is not redistributed here.

## Conformance corpus from Oils (Oil shell)

The spec-test conformance runner (`lua/spec.lua`, fetched via `test/spec/`) exercises curse against the
**Oils** spec tests (<https://oils.pub>, <https://github.com/oilshell/oil>),
Copyright the Oils authors, licensed under the **Apache License 2.0** — which is
compatible for inclusion in a GPLv3+ work. The tests themselves are **not**
redistributed here; `test/spec/fetch.sh` downloads them into `reference/oil/`
(gitignored). The runner compares curse's output to real bash (the oracle), so
it uses the test snippets, not their per-shell expectation annotations.
