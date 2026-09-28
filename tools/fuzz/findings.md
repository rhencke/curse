# AFL fuzz findings (spike-afl) — verified curse bugs

[SPIKE, not for merge.] Each entry was found by the AFL++ spike (tools/fuzz/), minimised with
afl-tmin, and checked against the pinned oracle build/test/oracle/bash (5.2.21) in the fuzz
sandbox (tools/fuzz/cmp.sh: empty PATH, builtins only, read-only fs, private tmpfs cwd).
"All tiers" = interp, compiled and tiered through the harness, plus the static build/curse
(cold, tiered). Every entry is a Lua error inside curse, which bash can never produce.

## F1. `set -o0` — Lua error `table index is nil` escapes the shell

    set -o0

- bash: lists the `set -o` options, then `S: line 1: set: -0: invalid option` + the set usage line, status 1.
- curse (all tiers): lists the options, then the script dies with an escaped Lua error
  (static binary: `curse.bundle:…: table index is nil` + a Lua stack traceback), status 1.
- Where: interp.lua:23 `sh[field] = on` in set_opt — `field` is nil (the option letter
  after `-o` in the same word, here `0`, is looked up as a set flag and the miss is not handled).

## F2. `$[$(` at EOF — parser error escapes as a raw Lua error, wrong status and message

    $[$(

(file with no trailing newline; `echo $[$(` behaves the same.)
- bash: `S: line 2: unexpected EOF while looking for matching `)'`, status 2.
- curse (all tiers): the parse error string escapes the run (interp.lua:5519 re-raises a
  non-table error from expand_args → finish) — static binary prints
  `curse.bundle:…: unexpected EOF while looking for matching `"'` + a Lua stack traceback,
  status 1. Wrong delimiter (`"` vs `)`), no `NAME: line N:` prefix, wrong status.
- Where: parser.lua:706 raises; the error is not a table (`__curse_experr`), so the
  expansion pcall in interp.lua (~5510) rethrows it and nothing above catches it.

## F3. `case 0 in $())|0` — Lua error text reported as a syntax error

    case 0 in $())|0

- bash: `S: line 1: syntax error near unexpected token `|'` and ``S: line 1: `case 0 in $())|0'``, status 2.
- curse (all tiers): `S: line 1: syntax error: attempt to index local 'first' (a nil value)`, status 2.
- Where (likely, not traced): parser.lua pipeline parse (~5221-5276) — `parse_command()`
  returns nil for a stage that begins at the stray `|`, and `first.t` is then indexed; the
  Lua error is caught by the syntax-error reporter and printed verbatim.

## F4. `declare -n` accepts an invalid target `A["]`; expanding it kills the script

    declare -n r='A["]'
    $r
    echo after

- bash: `S: line 1: declare: `A["]': invalid variable name for name reference` (declare
  fails), `$r` expands to nothing, `after` is printed, status 0.
- curse (all tiers): no declare diagnostic; `$r` raises the parser's
  `unexpected EOF while looking for matching `"'` as a raw Lua error that escapes the whole
  run (runtime.lua:3515 → tier.lua:397 → parser.lua:706 in the fuzz trace): nothing after
  it runs, status 1. Two bugs: the nameref target validation, and the escaping parse error
  (same escape as F2).

## F5. `"${u-'${'}"` — escaped parse error instead of bash's bad substitution

    echo "${u-'${'}"
    echo after

- bash: `S: line 1: bad substitution: no closing `}' in '${'`, the command fails (status 1)
  and the script continues: `after`, status 0.
- curse (all tiers): `unexpected EOF while looking for matching `''` as an escaped Lua
  error (interp.lua finish → parser.lua:706), script aborted, status 1.

## F6. Compiled tier: here-document EOF warning names the wrong line (tier disagreement)

    { <<EOF
    x; } &

- bash, curse interp, tiered, static: `S: line 2: warning: here-document at line 1 delimited
  by end-of-file (wanted `EOF')`, then `S: line 3: syntax error: unexpected end of file`, status 2.
- curse compiled tier only (`run.lua SCRIPT compiled`; the whole-program compile the
  daemon's hot path also uses): the warning says `line 3`. Found by the tier-disagreement
  oracle over the fuzz queue.

## F7. `;&` outside `case` — the error names the wrong token

    true;&echo x

- bash: `S: line 1: syntax error near unexpected token `;&'` (+ the line echo), status 2.
- curse (all tiers): `... near unexpected token `&'`, status 2.

## F8. `${! a}` (space after `!`) expands to nothing instead of a bad substitution

    echo ${! a}
    echo after $?

- bash: `S: line 1: ${! a}: bad substitution`, the echo fails, `after 1`.
- curse (all tiers): prints an empty line, then `after 0`. (Same across a newline:
  `echo t${! x<newline>}` — bash `bad substitution`, status 1; curse prints `t`, status 0.)

## F9. `trap -p` in a nested async list shows `trap -- '' SIGINT`

    { trap -p & } &
    wait

- bash: prints nothing, status 0.
- curse (all tiers): prints `trap -- '' SIGINT`. (One level, `trap -p &`, agrees with bash.)

## F10. Unterminated subscript at command start: wrong error

    a[b c
    echo after

- bash: `S: line 1: unexpected EOF while looking for matching `]'`, status 2 (the word
  `a[` starts an assignment-subscript scan that runs to EOF; nothing runs).
- curse (all tiers): `S: line 1: syntax error near unexpected token `a[b'` + the line echo, status 2.

## F11. Exit status after an EOF-in-quote parse error keeps the last command's failure

    nosuch
    echo 'x

- bash: `nosuch: command not found`, `unexpected EOF while looking for matching `''`, exit **127**
  (`false` first → exit 1; `true` first → 2).
- curse (all tiers): same messages, exit 2 regardless.

## F12. `"$$(( }` — `$$` followed by `((` inside double quotes

    echo "$$(( }

- bash: `S: line 1: unexpected EOF while looking for matching `"'`, status 2 (`$$` is the pid;
  the `((` is literal text in the unterminated string).
- curse (all tiers): `... matching `)'` (reads `$(( ` as an arithmetic expansion after the first `$`).

## F13. Huge printf field width: escaped Lua `not enough memory`

    printf '[%*d]' 9999999999 1
    echo after

- bash: clamps the width (2147483647 bytes of padding are written, plus
  `printf: warning: 1: Numerical result out of range`), then continues.
- curse (all tiers, under the fuzz sandbox's 2 GB RLIMIT_AS): builds the padded string in
  memory and dies with an escaped Lua `not enough memory`, status 1; `after` never runs.
  (The width clamp + that warning is the bash behaviour to copy; streaming the padding
  would avoid the allocation.)

## F14. Compiled tier: arithmetic error inside `(( a[0]++ ))` aborts the script, no `((: ` prefix

    a=x+
    (( a[0]++ ))
    echo after $?

- bash, curse interp / tiered / static: the `((: …` arithmetic error (a[0]'s value `x+`
  is evaluated as an expression), the command fails, `after 1`, status 0.
- curse compiled tier only: the message lacks the `((: ` prefix and the error is fatal —
  `after` never runs, status 1. (Found via the tier-disagreement oracle: a queue entry
  where `a=(10 20 30 40)for` made `a[0]`'s value an invalid expression.)

## F15. `$[ … ]` ignores quotes and backquotes when finding its `]`

    echo $[a `]
    echo after

- bash: the `$[` body is scanned like `$(( ))` (parse_matched_pair: quotes and backquotes
  nest), so the `` ` `` opens a command substitution that runs to EOF:
  ``S: line 1: unexpected EOF while looking for matching ``'``, nothing runs, status 2.
  Same with `"`: `echo $[a "]` → `... matching `"'`.
- curse (all tiers): closes `$[` at the first `]`, evaluates `a `` ` `` as arithmetic
  (`syntax error: invalid arithmetic operator`), prints `after`, status 0.
- By far the most frequent bash-vs-curse difference in the fuzz queue (~150 of 600 sampled
  entries: mutations of the `$[expr]` seed).

## Not listed as curse bugs (bash UB / harness)

- Unbounded function recursion (`f(){ f; }; f`, found as `0(){ …;0;}`): bash 5.2.21
  segfaults (status 139, stack exhaustion — bash UB, not in docs/bash-ub.md yet); curse
  stops with a bare `stack overflow` (compiled tier: `curse:compiled:9: stack overflow`), status 1.
  Candidate docs/bash-ub.md entry; the tiers' messages differ.
- Unbounded trap recursion (`trap '( kill -USR1 $$ )' USR1; kill -USR1 $$`): bash nests the
  handler without bound (still going at the 5 s limit); curse stops at ~610 levels with an
  escaped `stack overflow`. Same resource-exhaustion class. Note: with the JIT on, the fuzz
  crash inputs of this class did not reproduce in replay; with the JIT off (as the fuzz loop
  runs) they did every time — signal delivery timing differs between the two.
- Background-job output order and `jobs` Running/Done races, `times` figures, pids in
  messages (`$$`, `$!`, curse's synthetic 4194305+): nondeterminism; the triage diff does
  not mask digit runs yet, so these show up as noise.

# Grammar-aware mutator campaign (branch fuzz-grammar) — F16+

Found with tools/fuzz/gram_mutator.c + gram.lua (or, F20, by the byte-level instance of
the same campaign), reduced by hand or afl-tmin, and verified with tools/fuzz/cmp.sh
against the pinned oracle (5.2.21) in the fuzz sandbox. "All tiers" = interp, compiled,
tiered (harness) and the static build/curse. None of these is in F1-F15.

## F16. FIXED — Compiled tier: `while`/`until` status after a `continue` keeps an earlier iteration's failure

- FIXED (fix-fuzz2): a continue in while/until now re-tests through the body's status save (emit H.whilec). test/cases/2713.

    i=0; while ((i++ < 2)); do [ $i = 2 ] && continue; done; echo $?

- bash, curse interp / tiered / static: `0` (the last body command run was `continue`).
- curse compiled tier only: `1` (iteration 1's failed `[ $i = 2 ]`). `for` loops agree; a
  single iteration agrees. Found as `until ((…)); do …; [[ i -gt 105 ]] && continue; done`
  from the hot-loop wrapper (`… && echo True` then printed nothing).

## F17. FIXED — `>&3-` onto stdout with fd 3 closed: bash's extra "redirection error" line missing

- FIXED (fix-fuzz2): interp apply_redirs says it for a move run in the shell onto an open fd; a stage's / async command's own redirections exempt (rt.redir_top, both tiers). test/cases/2714.

    : >&3-

- bash: `S: redirection error: cannot duplicate fd: Bad file descriptor` then
  `S: line 1: 3: Bad file descriptor`, status 1.
- curse (all tiers): only the second line. (`: 4>&3-` agrees: the extra line is the
  save-stdout-for-the-builtin step failing.)

## F18. FIXED — Line numbers inside `$( )` whose first line ends in a pipe

- FIXED (fix-fuzz2): a $(…)/<(…) body is the text deparse re-prints (parser comsub_text; nested lists keep newline connectors; `$$'x'`). test/cases/2715.

    x=$( : |
    (a
    b)
    )

- bash: `S: line 4: a: command not found`, `S: line 5: b: command not found`.
- curse (all tiers): lines 5 and 6. (Without the `: |` both agree on 4/5.)

## F19. FIXED — `declare -i` on a dynamic variable with a value: escaped Lua error

- FIXED (fix-fuzz2): declare -i on a live dynamic variable: attribute, then its assign hook with the value as written (+= evaluates); plain assignments likewise. test/cases/2716.

    declare -i LINENO=1
    echo after

- bash: `after`, status 0 (same for BASH_COMMAND, BASH_SUBSHELL, BASHPID).
- curse (all tiers): `b_export:661: attempt to index local 'ib' (a nil value)` escapes,
  nothing after it runs, status 1. (`declare -i FUNCNAME=1` and ordinary names agree.)

## F20. FIXED — Local `declare var=([]= 0)` over a global assoc array: escaped Lua error

- FIXED (fix-fuzz2): a declaration's NAME=(…) for a new local is expanded as an indexed array's (rt.sr_aa_pre). test/cases/2717.

    declare -A var
    f() { declare var=([]= 0); }
    f; echo after $?

- bash: `S: line 1: []=: bad array subscript`, then `after 0`.
- curse interp, tiered, static: the same message, then `attempt to index local 'val'
  (a nil value)` (runtime.lua:9982) escapes; status 1. The compiled tier agrees with bash.
  (byte-level instance, afl-tmin'd.)

## F21. FIXED — `${v#pat}` / `%` / `/pat/rep` / `^` on an empty or unset v still expands the pattern

- FIXED (fix-fuzz2): rt.pe_nopat: the pattern/replacement expand only when the value takes them (interp thunks, compiled expands after the value). test/cases/2718.

    : ${A#$(echo hi >&2)}

- bash: nothing (an empty/unset value is returned before the pattern word is expanded;
  `A=x` does run it). Same for `${A%…}`, `${A/x/$(…)}`, `${A^…}`, `${a[@]#…}` with `a=()`.
- curse (all tiers): prints `hi`: the pattern's command substitution (any side effect)
  runs.

## F22. FIXED — Compiled tier with no writable temp dir: `$(cmd >&2)` captures cmd's stderr

- FIXED (fix-fuzz2): rt.redir_apply / redir_apply_one point builtins at fd 1 whenever sh.out isn't io.write. Proved in lua/test_tier.lua (rt.mktmpfd failing).

    x=$(echo hi >&2); echo "[$x]"
    # run with /tmp read-only and no writable $TMPDIR, e.g.
    # unshare -Urm sh -c 'mount -o remount,bind,ro /tmp; cd /; build/luajit lua/run.lua s.sh compiled'

- bash, curse interp / tiered: `hi` on stderr, then `[]`.
- curse compiled tier: `[hi]`. rt.mktmpfd fails, Shell:capture_inproc falls back to the
  Lua-buffer capture, and a builtin's `>&2` inside it writes into the buffer. Also turns
  `A=xy; echo ${A#$(echo x; echo ho >&2)}` into `xy`. (The fuzz sandbox had exactly this
  environment — read-only / — until this branch gave it a TMPDIR; every compiled-mode
  run of the spike and of this campaign's first half used the fallback.)

## F23. FIXED — "No such file or directory" for a command path with control bytes: bash doesn't quote it

- FIXED (fix-fuzz2): rt.spawn_errmsg names the file raw except for command not found; `exec` of a file with a missing interpreter. test/cases/2719.

    $'/x\001y'

- bash: `S: line 1: /x^Ay: No such file or directory` (raw byte), status 127.
- curse (all tiers): `S: line 1: $'/x\001y': No such file or directory`. (For a name
  without `/`, bash does quote: `$'x\001y': command not found` — curse agrees there.)

## F24. FIXED — `${!$}` expands instead of a bad substitution

- FIXED (fix-fuzz2): already fixed on main by e52103c (F8's `$$` scan): not reproducible at 1c505af; pinned by test/cases/2720.

    echo ${!$}; echo after $?

- bash: `S: line 1: ${!$}: bad substitution`, the echo fails, `after 1`.
- curse (all tiers): expands the indirection through `$$` (prints a line), `after 0`.
  (Neighbour of F8.)

## F25. FIXED — `local` of a readonly array outside a function: an extra "can only be used in a function"

- FIXED (fix-fuzz2): `local` outside a function localizes nothing in rt.sr_aa_pre: the readonly error is the line-fatal assignment's. test/cases/2721.

    local UID=(x)

- bash: `S: line 1: UID: readonly variable`, status 1 (also `local UID+=(x)`,
  `local -i UID+=(x)`; `local -a UID=x` agrees).
- curse (all tiers): the same line, then `S: line 1: local: can only be used in a function`.

## F26. FIXED — `[[ n -lt [[:class:]] ]]`: bash backslash-escapes the bracket expression in the error token

- FIXED (fix-fuzz2): parser cond_arith_word quotes an arith operand's subscript text; compiled [[ ]] reads unquoted `[` operands textually like interp. test/cases/2722.

    [[ 1 -lt [[:a:]] ]]

- bash: ``S: line 1: [[: [\[:a:\]]: syntax error: operand expected (error token is "[\[:a:\]]")``, status 1.
- curse (all tiers): `[[:a:]]` unescaped, both times. (`[[ 1 -lt [a] ]]` agrees.)

## F27. FIXED — Compiled tier: an arithmetic syntax error as a loop/if condition fails to compile, fatally

- FIXED (fix-fuzz2): cond_arith leaves a matherr (( )) condition to H.arithcmd. test/cases/2723.

    while ((0 0)); do :; done; echo after $?

- bash, curse interp / tiered / static: `((: 0 0: syntax error in expression (error token is "0")`, then `after 0`.
- curse compiled tier: `emit: value position not supported for node matherr` escapes,
  nothing runs, status 1. Same with `if ((0 0)); then :; fi` (`((0 0)) && :` agrees).
  Found by both compiled-mode instances (byte 42 crash inputs, grammar 2); afl-tmin'd to
  `(0);while((0 0))do 0⏎done`.

## F28. FIXED — Compiled tier: `$((P=${#x}))` (assignment of a `${#…}` inside `$(( ))`) fails to compile

- FIXED (fix-fuzz2): arith_side_effect looks into a fast xpand's native tree. test/cases/2724.

    f=$((P=${#x})); echo $f

- bash, curse interp / tiered / static: `0`.
- curse compiled tier: `emit: value position not supported for node asgn` escapes, status 1.
  (`$((P=$#))` agrees.)

## F29. FIXED — Compiled tier: a word of ~200 parts overflows LuaJIT's syntax nesting

- FIXED (fix-fuzz2): emit cat_exprs groups `..` chains; arith trees deeper than 48 take the shared evaluator; deep constants serialize flat (rt.unflat). test/cases/2725 (the census catches the old LOADFAIL).

    echo a\ba\ba\b…   # `a\b` 100 times, one word
    echo after

- bash, curse interp / tiered / static: prints the word, then `after`.
- curse compiled tier: `curse:compiled:N: chunk has too many syntax levels`, status 1 (the
  word's parts are emitted as one nested expression). Found as a 300-byte word of `''`
  and `\0` pieces from tok-bytes/wrap mutations.

## F30. FIXED — Compiled tier: an arithmetic error from a variable's value in `${v:off}` loses `line N:`

- FIXED (fix-fuzz2): substr_native declines variable-reading operands: rt.substr_arith labels the error. test/cases/2726.

    v=x+; echo ${v:v}

- bash, curse interp / tiered / static: `S: line 1: v: x+: syntax error: operand expected (error token is "+")`.
- curse compiled tier: `S: v: x+: syntax error: …` (no `line 1: `). Same for
  `v=v; echo ${v:v}` (`expression recursion level exceeded`). `echo ${v:1+}` agrees.
  (byte-level instance; a tier-disagreement found by the equal-sample differential.)

## Variants of known entries (not new)

- `x=a; echo ${x/${/}}` and `if 0&break;then select H in ${0[0]/${/}} do 0;done;fi`
  (afl-tmin): the escaped `unexpected EOF while looking for matching `}'` of F2/F5 (bash:
  `${/}: bad substitution`), through a pattern word and through `select`'s word list.
- `case 0 in 0)case 0 in⏎0)|0`: F3's `attempt to index local 'first'` from a nested case;
  `case a in a)|& x;; esac` gives the sibling `syntax error: attempt to index local 'prev'`
  (bash: `syntax error near unexpected token `|&'`) — same pipeline-parse gap, `|&` path.
- `set -v'for …` (a quote glued to the option word, byte-level): F1's `table index is nil`;
  in the harness this one surfaces as a crash signal with no message.
- Unbounded `source` recursion (`printf … > s; . ./s` wrapped twice) and eval recursion:
  the UB-recursion class (escaped `stack overflow`). A self-signalling trap
  (`trap 'kill -USR1 $$' USR1; kill -USR1 $$`) also dies by a crash signal with no
  message in the harness (bash: SIGSEGV, status 139).

## Harness fidelity fixes made on this branch (they hid or faked differences)

- The harness left its stderr memfd at fd 3: `: >&3-` and anything probing fd 3 saw an
  open fd. Moved to fd >= 210.
- No writable TMPDIR in the sandbox (read-only /): see F22.
- afl-cmin/afl-showmap need `__AFL_DEFER_FORKSRV=1` with this harness, or they read only
  the ~180 bytes of C edges (the spike's afl-seeds-min was minimised on that).

# F31+ fixed on branch fix-fuzz3 (the findings are on fuzz-docker; reconcile at merge)

- F48 FIXED — a "…" inside ${…} nests its own expansions (parse_matched_pair), and a $[…]
  in ${…} is scanned as one, so `"${x%${}"${"}"` is the parse-time EOF error; a ${…}
  operand re-read at expansion can no longer raise an escaped Lua error (interp lazy_word).
  test/cases/2729-dolbrace-nested-quote-eof.sh
- F51 FIXED — the compiled tier's `.` never hands the interpreter a nil hook, and eval/source
  text under `set -v` is read by the interpreter's reader (echoed). test/cases/2727-set-v-sourced-loop.sh
- F52 FIXED — lines read while -v was off are behind the reader: a `set -v` in sourced/eval'd
  text doesn't echo its own line; `set -v` in text the program hands to eval/source/a trap
  puts a compiled program in line mode. test/cases/2728-set-v-own-line.sh
- F31 FIXED — `${!a[@]x}`: after an indirect key list's subscript only an operator may
  follow; anything else is a bad substitution. test/cases/2730-indirect-keys-junk.sh
- F32 FIXED — a "…" whose ${…} has a `[` that never closes runs off the word (bash's
  extract_dollar_brace_string/skipsubscript, ported: parser dq_brace_open): "bad
  substitution: no closing `}' in WORD"; an unquoted `${!a[@}` is a `${!PREFIX@}`.
  test/cases/2731-dq-subscript-no-closing.sh
- F33 FIXED — `${}` is a bad substitution (was the empty string). test/cases/2732-empty-braces.sh
- F34 FIXED — `${!?}` is indirection through $? (VALID_INDIR_PARAM), an operator after it
  applies; other text after the `?` is a bad substitution. test/cases/2733-indirect-status.sh
- F35 FIXED — a subscript on a special/positional parameter is a bad substitution.
  test/cases/2734-special-param-subscript.sh
- F36 FIXED — every $name/$N of an arithmetic text is vetted before evaluating (untaken
  ternary arms / && || right sides too): non-numeric → bash's textual path.
  test/cases/2735-arith-untaken-branch-expansion.sh
- F37 FIXED — a subscript whose expansions leave nothing reads `NAME[]` in arithmetic (both
  tiers: rt.EMPTYSUB). test/cases/2736-arith-empty-subscript.sh
- F38 FIXED — a `$` inside "…" in arithmetic stays a character (textual path); the text shown
  in errors has the dropped `$`s dropped. test/cases/2737-arith-quoted-dollar.sh
- F39 FIXED — a name right after the expression: readtok's peek past a run of names reports
  a bad character as "invalid arithmetic operator". test/cases/2738-arith-name-peek-error.sh
- F40 FIXED — ERR/DEBUG/RETURN handler text numbered from the trapped line (interpreted:
  parsed with that line1, trap_abs; compiled: trap-relative pc lines, rt.pc_line), and a
  function it defines keeps those lines. test/cases/2739-trap-handler-lines.sh
- F41 FIXED — a syntax error at a token from an alias's text shows the alias text (its last
  character overwritten by the ungot delimiter). test/cases/2740-alias-token-syntax-error-line.sh
- F42 FIXED — a quote inside ${…}/$(…)/`…` doesn't make a here-document delimiter quoted;
  also a command whose 2nd token is a redirection runs at the operator's line.
  test/cases/2741-heredoc-delim-expansion-quotes.sh
- F43 FIXED — (with F36) the substituted text is parsed once: one "bad array subscript",
  then the syntax error. test/cases/2742-arith-subst-before-eval.sh
- F44 FIXED — a listing builtin (export, declare, set, readonly, compgen -v) doesn't list its
  own prefix bindings (rt.tenv_hide). test/cases/2743-prefix-assign-listing.sh
- F45 FIXED — a `\<newline>` ending the input counts as a line read (EOF syntax error, body
  warnings, joined body lines); a script's last `\` quotes nothing (body loses it and its
  newline); a string's (eval/source) stores the EOF as a 0xff byte — deterministic, copied.
  test/cases/2744-trailing-backslash-newline-eof.sh
- F46 FIXED — a bad substitution's text shows \001/\177 CTLESC-quoted.
  test/cases/2745-badsubst-ctlesc-bytes.sh
- F47 FIXED — a here-document opened in <(…)/>(…) reads its body from the following lines,
  as in $(…); a second here-document's warning names the line its reading began.
  test/cases/2746-procsub-heredoc-body.sh
- F49 FIXED — after an assignment/redirection prefix nothing is a reserved word.
  test/cases/2747-prefix-then-reserved-word.sh
- F50 FIXED — a syntax error where the line's list could end gathers the line's
  here-document bodies first (bash's simple_list reduction). test/cases/2748-syntax-error-pending-heredoc.sh
