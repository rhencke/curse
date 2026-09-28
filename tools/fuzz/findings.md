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

## F88. Interp mode: a recursive function that turns hot mid-recursion loses `BASH_LINENO` frames

    h() { r="${BASH_LINENO[*]}"; }
    x=$(:)
    y() { (( $1 > 0 )) && y $(( $1 - 1 )) || { h; echo "Y $r"; }; }
    y 150

- bash, curse tiered / compiled: 154 words (`Y 3 3 … 3 4 0`: one `3` per recursion level).
- curse interp (`curse SCRIPT interp`, harness FUZZ_MODE=interp): 103 words — the frames
  of the calls made before the function was compiled (the 100-pass threshold) are gone.
  At `CURSE_HOT_LOOP=3`, `y 3` already prints `Y 3 3 3 4 0`. Needs a command substitution
  before the definition (`x=$(:)`, `$(nosuch)`, `for i in $(…)`); without it all agree.
- Found by the tier oracle (FUZZ_ORACLE=tiers, interp vs compiled) on test/cases/2492 run
  in the sandbox (no `seq` there: its loops don't run, which leaves the `$(seq …)` alone).

## F89. A process substitution's output leaks into `$( )` when the command isn't found

    x=$(nosuch <(echo leak)); echo "[$x]"

- bash: `S: line 1: nosuch: command not found`, `[]` (the process substitution writes to its
  pipe; nobody reads it).
- curse (all tiers): `… command not found`, `[leak]` — the process substitution's output
  becomes the command substitution's. `x=$(nosuch <(echo leak) 2>/dev/null)` gives `[]`, and
  at top level (`nosuch <(echo leak)`) nothing leaks. Found (tier-oracle host smoke,
  test/cases/2019 in the sandbox: `declare -a arr=($(cat <(echo 1 2)))` with no `cat`).

## F90. Compiled tier: `command not found` inside `$( )` in an assignment names an earlier line

    eval 'cat' <(echo x) 2>/dev/null; echo "st=$?"
    declare -a arr=($(cat <(echo 1 2)))
    typeset -n r1=r2; typeset -n r2=r1

- bash, curse interp / tiered: `S: line 2: cat: command not found` (after `st=127`).
- curse compiled: `S: line 1: cat: command not found`. Each of the three lines is needed
  (the nameref cycle at the end changes how the file compiles). Found by the tier oracle
  (compiled vs interp) on test/cases/2019 in the sandbox (no `cat`).

## F91. Compiled tier: a special builtin's usage error leaves its `2>/dev/null` in place

    shift 1 2 2>/dev/null
    ( nosuch )

- bash, curse interp / tiered: `S: line 2: nosuch: command not found`.
- curse compiled: nothing — stderr stays redirected to /dev/null after `shift`'s "too many
  arguments" abandons the line, for the rest of the script. Found by the tier oracle
  (compiled vs interp) on test/cases/1640 in the sandbox.

## F92. Interp / tiered under `set -x`: `[[ $s == "…" ]]` with a quoted high byte fails to match

    s=$'a\x81b'; set -x; [[ $s == "a<0x81>b" ]]; echo $?

(`<0x81>` is the raw byte; LC_ALL=C.)
- bash, curse compiled: status 0; the trace line is `+ [[ a<81>b == \a\<81>\b ]]`.
- curse interp / tiered: status 1 (without `set -x` all agree: 0); the trace line is
  `+ [[ a<81>b == \a<81>\b ]]` in every tier (the byte isn't backslash-quoted; bash quotes
  it). Found by the tier oracle (interp vs compiled status) on test/cases/2560 run in
  LC_ALL=C.

## F93. `bash -c`: an expansion error in a subshell exits it with 127 instead of 1

    bash -c '( : ${x?} ); echo "sub=$?"'

- bash: `bash: line 1: x: parameter not set`, `sub=1` (a script file: also 1).
- curse (all tiers, `-c` only): `sub=127` — the `-c` top level's 127 is applied to the
  subshell. `( : $((1/0)) )` agrees (1). Found while building the targeted fuzzers'
  driver (host smoke); the drivers run as a script file, which doesn't hit it.

## F94. `set -n`: a `time` pipeline still prints its timing report

    set -n
    time echo hi

- bash: nothing (noexec: nothing runs, `time` included), status 0. Same for
  `eval $'set -n\ntime echo hi'`.
- curse (all tiers): the `real/user/sys` report for the pipeline that didn't run.
  Found by the parse target (host smoke over test/cases: 780-time).

## F95. `set -n`: no "here-document … delimited by end-of-file" warning for a here-doc in `$( )`

    set -n
    z=$(cat <<EOF
    hey
    EOF  )

- bash: `S: line 4: warning: here-document at line 2 delimited by end-of-file (wanted `EOF')`
  (the command substitution is parsed with the script, run or not).
- curse (all tiers): nothing under `set -n` (without it, the same warning as bash) — the
  `$( )` body is only read when it runs. Found by the parse target (test/cases/2521).

## F96. `declare -f`: `$'…'` in an array literal or a `${…}` operand printed untranslated

    f() { a=(x $'t\tu' p$'\0'q); echo "${x-$'a\tb'}"; }; declare -f f

- bash: `a=(x 't<TAB>u' p''q)` and `"${x-a<TAB>b}"` (the ANSI-C string is translated when
  parsed: `\0` ends it).
- curse: `a=(x $'t\tu' p$'\0'q)` and `"${x-$'a\tb'}"`. A plain word (`echo $'t\tu'`)
  agrees (`'t<TAB>u'`). Found by the deparse target (test/cases 1480, 1950, 2140, 2210,
  2360, 2402, 2474, 2567, 2675).

## F97. `declare -f` drops a literal `$` inside `"${x+"…"}"`

    f() { p "${x+"$"}" "${u-"a$"}" "${x+$"t"}"; }; declare -f f

- bash: `p "${x+"$"}" "${u-"a$"}" "${x+"t"}"`.
- curse: `p "${x+""}" "${u-"a"}" "${x+$"t"}"` — the printed body loses the `$` (running
  `f` itself is right: `echo "${x+"$"}"` prints `$`), so re-sourcing the printed function
  changes it. Found by the deparse target (test/cases/2220).

## F98. `declare -f`: other printer differences (deparse target over test/cases; not minimised)

- `echo d >&4294967297` printed as `echo d 1>&4294967297` (bash: `>&4294967297`) (1910).
- A brace group / function body ending a line: `};` vs bash's `}` (2180); `for ((i=0; i<1;
  i++))` split across lines in the source prints differently (2490, 2563); `[[ 1 -lt
  [[:a:]] ]]` (bash: `[\[:a:\]]`, 2722); a `case` inside `<( )` (860), an alias inside a
  `$( )` (2568), `$( )` line numbers (2715), `$(echo side >&2)` inside an array literal
  (2080: bash `1>&2`), `declare -a e1=( $(…) … )` spacing (2010), `exec 3> >(cat >out)`
  (2533: bash `cat > out`). Each is `deparse` target output vs bash on the named
  test/cases file; minimise one before fixing it.

## Found by the in-loop oracles' first containerized campaigns (fuzz-ruthless validation)

Each was found by a targeted fuzzer (9-min campaigns in `fuzz-docker`, FUZZ_INSTANCES
`gram:TARGET`) and re-checked, reduced by hand, with `cmp.sh` in the container: bash
5.2.21 vs curse interp / compiled / tiered / static. Unless noted, every tier gives the
curse result shown ("all tiers").

## F99. Arithmetic: a compound assignment with no lvalue loses the operator's first byte in the error token

    e='+=*63-1'; echo "$(( $e ))"

- bash: `operand expected (error token is "+=*63-1 ")`; curse (all tiers): `(error token is "=*63-1 ")`.
  Same for `2*+=3-1`, `2**+=-1`. (arith target)

## F100. Arithmetic: a bad subscript through a nameref names the nameref

    w=x; declare -n ref=w; e='ref[-10]'; echo "$(( $e ))"

- bash: `S: line 1: w: bad array subscript`, then `0`; curse (all tiers): `ref: bad array subscript`. (arith)

## F101. Arithmetic: a double-quoted operand in an expanded expression is accepted

    e='2**"1"'; echo "$(( $e ))"; e='up="1"'; echo "$(( $e ))"

- bash: `syntax error: operand expected (error token is ""1" ")`, status 1.
- curse (all tiers): `2` / `1` (the quotes are removed). `e='"1"A[1]'`: bash the same
  operand-expected error, curse `1A: value too great for base`. (arith)

## F102. Arithmetic: `y[t]y[|` — bash's "bad array subscript"

    e='y[t]y[|'; echo "$(( $e ))"

- bash: `y[t]y[| : bad array subscript (error token is "y[| ")`; curse (all tiers):
  `syntax error: invalid arithmetic operator (error token is "[| ")`. (arith)

## F103. Arithmetic: `v[1]++` on an integer scalar drops its value as element 0

    declare -i ii=3; e='ii[1]++'; echo "$(( $e ))"; declare -p ii

- bash: `declare -ai ii=([0]="3" [1]="1")`; curse (all tiers): `declare -ai ii=([1]="1")`. (arith)

## F104. Arithmetic: a form feed is whitespace to curse, not to bash

    e=$'\f\f'; echo "$(( $e ))"

- bash: `syntax error: operand expected (error token is "<FF><FF> ")`, status 1; curse (all
  tiers): `0`, status 0. (arith)

## F105. Arithmetic: `x='x-[AB)1'; $(( x ))` — recursion vs syntax error (compiled: no line)

    x='x-[AB)1'; echo "$(( x ))"

- bash: `x-[AB)1: expression recursion level exceeded (error token is "x-[AB)1")`.
- curse interp / tiered / static: `S: line 1: x-[AB)1: syntax error in expression`;
  compiled: the same without `line 1: `. (arith)

## F106. Arithmetic: a quote-broken `${` inside a subscript of an expanded value escapes as a Lua error

    e="p[++\${'k]}]2*A["; echo "$(( $e ))"      # fuzz input: 2*p[++${'k]}]2*A[

- curse (harness-plain, each of 14 inputs of this shape): the run's pcall fails with
  `interp:… b_eval:… interp:5760: interp:1144: parser:756: unexpected EOF while looking
  for matching `'`' (the F2/F5 class through the arithmetic subscript path). (arith; not
  yet reduced outside the harness)

## F107. `${v:OFF:+$@}`-style substring offsets containing `$@`

    set -- p1 'p 2' '' '*'; p='*o*'; t=$'\t x \t'; echo ${t:gggg:+$@}

- bash: `S: line 1: t: *o*: syntax error: operand expected (error token is "*o*")`.
- curse (all tiers): `t: +p1 p 2  *: syntax error in expression (error token is "p 2  *")`
  — the offset is expanded differently before evaluation. (pexp)

## F108. `${a:+~}` unquoted with an empty `$HOME`: bash keeps an empty field

    HOME=; a=(one); printf '<%s>' ${a:+~} x; echo

- bash: `<><x>`; curse (all tiers): `<x>`. (pexp)

## F109. printf: a negative precision in the format (`%.-1d`) is printed, not an error

    printf '[%.-1d]\n' 5

- bash: `[%.0-1ld]`, status 0 (bash rewrites the spec and passes the rest through);
  curse (all tiers): `[` + `printf: `-': invalid format character`, status 1. Every
  `%…-…` shape the fuzzer made (`%--.-1x`, `%*.-1y`, `%5.-1A`) is this. (printf)

## F110. Pattern matching: an unclosed extglob group matches in bash, not in curse

    shopt -s extglob; p='**([[:'; s=; [[ $s == $p ]]; echo $?      # also p='*!(Q'

- bash: `0`; curse (all tiers): `1` (also without extglob on). (glob)

## F111. Pattern matching: `[]a[.a.F]` against `]`

    p='[]a[.a.F]'; s=']'; [[ $s == $p ]]; echo $?; case $s in $p) echo c1;; *) echo c0;; esac

- bash: `1`, `c0` (an invalid collating symbol makes the bracket fail); curse (all tiers):
  `0`, `c1`. (glob)

## F112. `read -N N -a arr` splits the text; bash stores it whole

    read -N 99 -a arr <<< 'a b'; declare -p arr

- bash: `declare -a arr=([0]=$'a b\n')`; curse (all tiers): `([0]="a" [1]="b")`. (read)

## F113. `read -N 1 -r -a arr` of an IFS-whitespace character

    read -N 1 -r -a arr <<< $' \t'; declare -p arr

- bash: `declare -a arr=([0]=" ")`; curse (all tiers): `declare -a arr=()`. (read)

## F114. `read -d '\'` (backslash delimiter, no -r): the status at end of input

    read -d '\' x <<< 'ab c\'; echo "st=$? [$x]"

- bash: `st=1 [ab c]`; curse (all tiers): `st=0 [ab c]`. (read)

## F115. `[[ … =~ … ]]`: bash's parse errors for `;` in a bracket and a trailing `\ `

    [[ x =~ ^[^;]+ ]]; echo $?
    [[ x =~ ab\  ]]; echo $?

- bash: `syntax error in conditional expression: unexpected token `;'`, `syntax error near
  `;]'` (`;'`), the line, status 2; curse (all tiers): `0` / `1` — the regex is accepted.
  `[[ x =~ ^(a|b^ ]]`: bash `unexpected EOF while looking for matching `)'`, curse `…
  looking for `]]'`. (regex: curse's parser passed the gate, bash's didn't)

## F116. Parser: constructs bash rejects run in curse

    eval '<<<'; echo st=$?
    eval ']] &'; echo st=$?

- bash: `syntax error near unexpected token `newline'` / `` `]]' ``, st=2; curse (all
  tiers): `st=0` / `]]: command not found`, st=0. (parse)

## F117. Parser: the unexpected token named in a syntax error

| input (eval) | bash | curse (all tiers) |
|---|---|---|
| `}(x` | `` `}' `` | `` `x' `` |
| `for  #3` | `` `newline' `` | `` `#' `` |
| `ech<<<<<<<<` | `` `<<<' `` | `` `newline' `` |
| `: $(( ${#a` | EOF looking for `` `)' `` | EOF looking for `` `}' `` |
| `&>$(x`, `+($(x`, `$\`⏎`(x` | EOF looking for `` `)' `` (line+1) | `` `&' `` / `` `$' `` / `` `x' `` |

(parse; `time --` under `set -n` printing timings is F96.)

## F118. `${v[-1]}` on a scalar: bash's "bad array subscript" is missing

    n=5; echo "[${n[-1]}]"; echo "[${n[-1]:-d}]"; echo "[${#n[-1]}]"; echo end

- bash: `S: line 1: n: bad array subscript` then `[]`, again then `[d]`, then
  `S: line 1: -1]: bad array subscript` and the rest of the script is skipped (the `${#…}`
  one is fatal), status 1.
- curse (all tiers): `[]`, `[d]`, `[0]`, `end` — no error at all. The largest pexp group
  (~130 of 377 unbucketed signatures). (pexp)

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

# Docker campaign (branch fuzz-docker) and the previous triage's unexplained signatures — F31+

F53-F79 are from the 60-min `fuzz-docker` campaign's triage (and F37/F36 got variants);
every repro below was run through the capped container (tools/fuzz/docker/run.sh exec).
F31-F50 and F52 are the 38 NEW differential signatures the previous triage
(main build/fuzz-work/triage/20260927-225416) left unexplained, re-checked against current
main (F1-F30 fixed) and reduced by hand or with a ddmin over bytes; F48 came from the
containment probe's AFL run, F51 from the 60-min `fuzz-docker` campaign
(`gram:tiered gram:compiled`). Verified with tools/fuzz/cmp.sh against the pinned oracle
(5.2.21). "All tiers" = interp, compiled, tiered (harness) and the static build/curse.
The rest of those 38 were NOISE (output order of async constructs, a SIGPIPE race, a
signal race; known.tsv), one is UB (unbounded recursion), one now agrees.

## F31. FIXED — `${!a[@]x}` (junk after the subscript of an indirect key list) expands instead of a bad substitution

    a=(1 2); echo "${!a[@]x}"

- bash: `S: line 1: ${!a[@]x}: bad substitution`, status 1.
- curse (all tiers): `S: line 1: 1 2: invalid variable name` (the keys are expanded, then
  used as an indirect name). Found as `"${!a[@][a-z]{a[@]}"`, `"${!a[@]while{a[@]}"`.

## F32. FIXED — `${!a[@}` (unclosed subscript): bash's "no closing" wording missing

    echo "${!a[@}"

- bash: `S: line 1: bad substitution: no closing `}' in "${!a[@}"`.
- curse (all tiers): `S: line 1: ${!a[@}: bad substitution`. Also `"${!a[@]{a[}"`
  (curse: `a[@]: invalid indirect expansion`).

## F33. FIXED — `${}a` expands to `a` instead of a bad substitution

    echo "${}a"; echo "st=$?"

- bash: `S: line 1: ${}a: bad substitution`, the command fails, `st=1`.
- curse (all tiers): prints `a`, `st=0`. (`"${}"` alone agrees.)

## F34. FIXED — `${!?x]}`: bash's bad substitution, curse the `${!?word}` error

    echo "${!?x]}"

- bash: `S: line 1: ${!?x]}: bad substitution`.
- curse (all tiers): `S: line 1: !: x]` (read as `${!?word}` on `$!`).

## F35. FIXED — A subscript on a special or positional parameter (`${*[0]}`, `${2[-1]}`) is not a bad substitution

    set -- a; echo "${*[0]}" "${2[-1]~}"; echo "st=$?"

- bash: `S: line 1: ${*[0]}: bad substitution`, `st=1`.
- curse (all tiers): prints `a `, `st=0` (`${2[-1]~}` alone: `2: bad array subscript`).
  Found as `"${*[-1]@a}"`.

## F36. FIXED — `(( 1 ? 0 : $i ))` with an empty branch: no expression error

    (( 1 ? 0 : $i )); echo "st=$?"

- bash: `S: line 1: ((: 1 ? 0 :  : expression expected (error token is ":  ")`, `st=1`.
- curse (all tiers): no message, `st=1`. (`$(( 1 ? 2 : ))` agrees, but
  `echo $(( 1 - a[4]++ ? 0 : $x ))` doesn't: bash `… expression expected`, curse prints `0`.)

## F37. FIXED — An empty subscript in arithmetic (`v[$a]`, a empty) is not a bad array subscript

    a=; (( v[$a] ? 1 : 2 )); echo "st=$?"

- bash: `S: line 1: v[]: bad array subscript` twice, `st=0`.
- curse (all tiers): no message, `st=0`. Nested: `echo $(( A[x[$f]] ))` — bash
  `x\[\]: syntax error: invalid arithmetic operator (error token is "\[\]")`, curse `0`
  (in a recursive function the fuzz input then ran into curse's stack overflow).

## F38. FIXED — `$(( "$"@ ))`: the error token loses the `$`

    x=$(( "$"@ ))

- bash: `S: line 1: $@ : syntax error: operand expected (error token is "$@ ")`.
- curse (all tiers): `… @ : syntax error: operand expected (error token is "@ ")`.

## F39. FIXED — A subscript spanning lines: `invalid arithmetic operator` becomes `syntax error in expression`

    echo "${a[x
    y@]}"

- bash: `S: line 2: x` / `y@: syntax error: invalid arithmetic operator (error token is "@")`.
- curse (all tiers): `… y@: syntax error in expression (error token is "y@")`. On one
  line (`${a[y@]}`) both agree.

## F40. FIXED — A function defined in an ERR trap action: its line numbers

    trap 'f() {

    foo
    }' ERR; false; f

- bash: `S: line 6: foo: command not found`.
- curse (all tiers): `S: line 3: foo: command not found`. (A USR1 trap agrees.)

## F41. FIXED — Syntax error from an alias-expanded token: the echoed line

    shopt -s expand_aliases
    alias local='}'
    f() {
      local a
    }

- bash: `S: line 4: syntax error near unexpected token `}'` then `S: line 4: ` '` (the
  input line as bash's alias expansion left it).
- curse (all tiers): the second line is the source line, `S: line 4: `  local a'`.

## F42. FIXED — A here-document delimiter with quotes inside `${…}`: the warning names it unquoted

    cat <<${x"y"}

- bash: `… delimited by end-of-file (wanted `${x"y"}')` (quote removal leaves `${…}` alone).
- curse (all tiers): `(wanted `${xy}')`. Found with a delimiter spanning lines (`<<${a() {`…),
  where the `cat: command not found` line number differs as well (bash 2, curse 6).

## F43. FIXED — `A[-1]` on an unset A next to an arithmetic syntax error: doubled / lost messages

    (( (A[-1] || $a) ))
    (( 2#101 < (A[-1] != 1 || $a) ))

- bash: each prints `A: bad array subscript` once, then the `((: … operand expected` error.
- curse (all tiers): the first prints `A: bad array subscript` twice; the second prints it
  once and never the syntax error.

## F44. FIXED — `A=1 export` lists the temporary assignment

    A=1 export

- bash: the exported variables, no `A`.
- curse (all tiers): also `declare -x A="1"`. Same through `eval`.

## F45. FIXED — A backslash-newline at end of file: bash's line number is one higher

    cat <<EOF
    x\

- bash: `S: line 3: warning: here-document at line 1 delimited by end-of-file (wanted `EOF')`.
- curse (all tiers): `S: line 2: …`. Same off-by-one for an unterminated quote ending
  `'\`: `f() {⏎  echo '6⏎}⏎'\` → bash `line 6: syntax error: unexpected end of file`,
  curse line 5.

## F46. FIXED — `\001` / `\177` in a bad substitution's message: bash shows its CTLESC quoting

    printf 'echo "${a\001}"\n' > s; . ./s

- bash: `S: line 1: ${a^A^A}: bad substitution` (the byte doubled: CTLESC-escaped inside
  double quotes, printed raw); `\177` shows as `^A^?`.
- curse (all tiers): `${a^A}` (the byte once). A bash quirk to copy (bug-for-bug).

## F47. FIXED — A here-document inside `>( )` / `<( )`: not read like one inside `$( )`

    echo >(cat <<EOF)
    body
    EOF
    echo after

- bash: `S: line 1: warning: command substitution: 1 unterminated here-document`, then
  the body lines are the here-document (`cat` runs at line 3), `after`.
- curse (all tiers): `here-document at line 1 delimited by end-of-file`, then `body` and
  `EOF` run as commands.

## F48. FIXED — `"${x%${}"${"}"`: the parse error escapes (F2/F5 class, another path)

    x=1; echo "${x%${}"${"}"; echo after

- bash: `S: line 1: unexpected EOF while looking for matching `}'`, status 2.
- curse (all tiers): an escaped Lua error (`interp:6555: … parser:707: unexpected EOF while
  looking for matching `"'`), no `line N:` prefix, wrong delimiter. (`… ${; …` without
  the second quote gives the prefix but the same wrong delimiter.) Found by the containment
  probe's AFL run as `${0=*}…"${BASH_LINENO/%${*[0]%$""${_//${b^a}}…`.

## F49. FIXED — `}` after a redirection-only prefix is a word, not a closer

    <<F }; echo st=$?

- bash: `S: line 1: }: command not found`, the here-doc warning, `st=127`.
- curse (all tiers): `syntax error near unexpected token `}'`, status 2. Same for `>/dev/null }`.

## F50. FIXED — A syntax error on a line with a pending here-document: reported before the body is read

    cat <<EOF; }
    x

- bash: reads the body first: `S: line 2: syntax error near unexpected token `}'`,
  `S: line 2: `cat <<EOF; }'`, then the here-doc EOF warning.
- curse (all tiers): `line 1:` for both, no warning.

## F51. FIXED — Compiled tier: a loop in a sourced file running `alias` / `set -v` — escaped `attempt to call … 'hook'`

    printf 'for i in 1; do alias; done' > s; . ./s
    printf 'for i in 1; do :; done' > s; set -v; . ./s

- bash, curse interp / tiered / static: no output (resp. the line echoed), status 0.
- curse compiled tier: `attempt to call local 'hook' (a nil value)` (interp.lua:6208 via
  tier.lua:397, b_source; or `upvalue 'hook'`, interp.lua:5747/5798), an AFL crash. Any
  loop kind (`for`, `for ((`, `while`, `select`); `for i in 1; do :; done` alone agrees.
  Found as `select … do set -v; break; done` and `for((;;))do alias; done` sourced.

## F52. FIXED — `set -v` inside a sourced file or an eval string echoes its own line

    printf 'set -v\necho x\n' > s; . ./s

- bash: `echo x` then `x` (verbose starts with the next line read).
- curse (all tiers): also `set -v` itself first. Same for `eval 'set -v⏎echo x'` and for
  `set -v; echo x` on one line in the file (bash: nothing echoed).

## Not curse bugs (this triage)

- Unbounded recursion through `local a[3]=4` (`f() { local a[3]=4; f; }; f`): bash runs
  until killed (or segfaults) — UB-recursion. Note: curse's stack exhaustion surfaces as
  `S: line 1: 3: syntax error in expression` (the subscript's arithmetic catches it)
  instead of `stack overflow`.
- Output order only (every line and the status equal, cmp.sh now labels these
  `order-only:`): background jobs, coprocs, process substitutions, pipeline stages.
- `f | <a command that fails at once>`: whether f's later lines run depends on when the
  reader exits (SIGPIPE race). `{ trap ':' USR1; kill -USR1 $$; }` in a pipeline stage:
  a signal to the main shell racing the other stage.

## F53. FIXED — `A=$((()))$(())`: the arithmetic error escapes as a parse error

    A=$((()))$(())

- bash: `S: line 1: (): syntax error: operand expected (error token is ")")`.
- curse (all tiers): escaped `unexpected EOF while looking for matching `"'` (no prefix);
  an AFL crash. `echo $((()))$(())` agrees: only in an assignment value.

## F54. FIXED — `$[${]`: escaped parse error instead of a bad substitution

    echo $[${]

- bash: `S: line 1: ${: bad substitution`.
- curse (all tiers): escaped `unexpected EOF while looking for matching `}'`. Also `A=$[${]`.

## F55. FIXED — `${x/${/}}` still escapes (listed under "Variants of known entries" as F2/F5's, never fixed)

    x=a; echo ${x/${/}}

- bash: `S: line 1: ${/}: bad substitution`.
- curse (all tiers): escaped `unexpected EOF while looking for matching `}'`. Found as
  `{ "${#/${/}}";}`; 39 of the campaign's 46 crash inputs are F53/F54/F55.

## F56. FIXED — An arithmetic error in a subscript inside an EXIT trap: `(non-string error)` escapes

    trap '$[a[!]]' EXIT

- bash: `S: line 1: !: syntax error: operand expected (error token is "!")`, status 1.
- curse interp/compiled/tiered: the same line, then `(non-string error)`; static:
  `…/bash: (error object is not a string)`; status differs. An AFL crash.

## F57. FIXED — `for NAME in WORDS do` / `select NAME in WORDS do` (no `;`) is accepted

    for i in a do :; done
    select S in a do :; done

- bash: `syntax error near unexpected token `done'`, status 2.
- curse (all tiers): runs (`do` is taken as the loop keyword; select prints its menu).

## F58. FIXED — `$(for i in 1; do break 2; done)`: escaped `attempt to compare number with nil`

    echo $(for i in 1; do break 2; done)

- bash, curse compiled: an empty line.
- curse interp / tiered / static: `curse:eval:16: attempt to compare number with nil` (the
  comsub's lifted chunk), status 1. Found inside a `select` word list.

## F59. FIXED — The `select` menu is always one column

    select x in aaaaaaaaaaaaaa b c d e; do break; done <<< 1

- bash: columns across `COLUMNS` (80): `1) aaaaaaaaaaaaaa  3) c` / `2) b ...`.
- curse (all tiers): one item per line (runtime select_menu has no print_select_list layout).

## F60. FIXED — A syntax error inside `<( )` / `>( )` is not a parse error of the script

    cat <(:
    function f)

- bash: `S: line 2: syntax error near unexpected token `)'`, the script stops (status 2).
- curse (all tiers): `cat: command not found`, then `line 4: syntax error: unexpected end
  of file` (the body is parsed when it runs). `$( )` agrees. Probably F47's root.

## F61. FIXED — Interp/tiered: a missing operand after `?:` is not diagnosed

    echo $(( i ? $v ? 1 : 2 : 3 ))
    echo $(( 0 ? 1 : a && $a ))x

- bash, curse compiled: `… syntax error: operand expected (error token is "? 1 : 2 : 3 ")` /
  `(… "&&  ")`, status 1.
- curse interp / tiered / static: print `3` / `0x`, status 0 (also `$[(FUNCNAME) ? $b : x]`).

## F62. FIXED — Compiled tier: an arithmetic error in a `for … in` word list names the line of `do`

    for a in $(( 1 ? : 3 ))
    do echo in; done

- bash and the other tiers: `line 1:`; compiled: `line 2:`.

## F63. FIXED — `shift x 2`: argument count checked before the numeric check

    shift x 2; echo after $?

- bash: `shift: x: numeric argument required`, `after 1`.
- curse (all tiers): `shift: too many arguments`, and the script exits.

## F64. FIXED — A trap handler re-entered from itself: line numbers restart

    trap '((n++ < 1)) && kill -USR1 $$
    foo' USR1; kill -USR1 $$

- bash: `S: line 2: foo: command not found` twice.
- curse (all tiers): `line 1:` for the inner run, `line 2:` for the outer.

## F65. FIXED — A quoted word before `()` is a function definition to bash's parser

    'f'() { echo hi; }; echo st=$?
    ''()

- bash: `` `'f'': not a valid identifier ``, `st=1`; `''()` → `line 2: syntax error:
  unexpected end of file`.
- curse (all tiers): `syntax error near unexpected token `)'`, status 2.

## F66. FIXED — `${#v[x y]}` with v unset: bash never evaluates the subscript

    echo ${#v[x y]}

- bash: `0`. curse (all tiers): `x y: syntax error in expression (error token is "y")`.
  With `v=(1)` both give the error.

## F67. FIXED — Compiled tier: a function definition does not reset `$?`

    false; g () { :; }; echo $?

- bash and the other tiers: `0`; compiled: `1`.

## F68. FIXED — Compiled tier: an internal name leaks into an arithmetic error

    echo $(( x[ $v < ${#a} ] ))

- bash and the other tiers: `< 0 : syntax error: operand expected (error token is "< 0 ")`.
- compiled: `… "< __curse_len_a "`.

## F69. FIXED — `for x >&f`: the unexpected token is `>&`, not `>`

    for x >&f

- bash: `syntax error near unexpected token `>&'`. curse (all tiers): `` `>' ``. Same in eval.

## F70. FIXED — An unterminated `$[` in a here-document inside `$( )`

    x=$(cat <<EOF
    $[a[
    EOF
    )

- bash: `S: line 4: bad substitution: no closing `]' in $[a[` (the rest of the body echoed).
- curse (all tiers): an arithmetic error with the body's text: `S: line 4: a[` /
  `: bad array subscript (error token is "a[` / `")`.

## F71. FIXED — A redirection error on a multi-line compound names its last line

    for ((;;))
    do
    break
    done {v}>> $a

- bash: `S: line 1: v: ambiguous redirect`. curse (all tiers): `line 4:`.

## F72. FIXED — `(( BASH_COMMAND ))`: the recursion error's token (and compiled: no line)

    (( BASH_COMMAND ))

- bash: `… expression recursion level exceeded (error token is "BASH_COMMAND ))")`.
- curse: `(error token is "(( BASH_COMMAND ))")`; compiled also drops `line 1: `. With
  `!!BASH_COMMAND & $A` curse says `syntax error in expression` instead.

## F73. FIXED — An arithmetic error in `(( ))` shows `${…}` unexpanded

    b=; (( 2 % (i /= i[${#b}]) ))

- bash: `((: 2 % (i /= i[0]) : division by 0 …`. curse (all tiers): `… i[${#b}]) …`.

## F74. FIXED — `1 ? (0) ? ~x *= 1 : 2 : 3`: the wrong error

    echo $(( 1 ? (0) ? ~x *= 1 : 2 : 3 ))

- bash: `attempted assignment to non-variable (error token is "*= 1 : 2 : 3 ")`.
- curse (all tiers): `` `:' expected for conditional expression `` (same token).
  Same family: `echo $(( ((b) ^ A /= 2) ))` — bash `attempted assignment to non-variable`,
  curse `` missing `)' ``.

## F75. FIXED — `$\A` in an arithmetic subscript: bash removes the backslash in the message

    echo $[a[$\A]]

- bash: `$A: syntax error: operand expected (error token is "$A")`. curse: `$\A` both places.

## F76. FIXED — Compiled tier: a backquote inside `[[ ]]` reports the previous line

    (( 1 ))
    [[ ( `export -f b[]=` -gt 1 ) ]]

- bash and the other tiers: `S: line 2: export: b[]=: not a function`; compiled: `line 1:`.

## F77. FIXED — `[[ !(a >| b) ]]`: bash's parse-error wording

    [[ !(a >| b) ]]

- bash: `unexpected token `>|', conditional binary operator expected`, then `syntax error
  near `|'`. curse (all tiers): `expected `)'`, `syntax error near `b)'`.

## F78. FIXED — `[[ x -le @(a|b) ]]` without extglob: a parse error in bash

    [[ x -le @(a|b) ]]

- bash: `syntax error in conditional expression: unexpected token `('`, status 2.
- curse (all tiers): evaluates it: `[[: @(a|b): syntax error: operand expected`.

## F79. FIXED — Interp/tiered: `break` in a `for` word list's command substitution

    for i in `break -1 b`; do :; done

- bash, curse compiled: `break: too many arguments`.
- curse interp / tiered / static: `break: only meaningful in a `for', `while', or `until' loop`.

## F80. FIXED — Two here-documents on one line: the second's EOF warning names line 1

    cat << A << B

- bash: `… here-document at line 1 … (wanted `A')`, then `… at line 2 … (wanted `B')`.
- curse (all tiers): `at line 1` for both.

## F81. FIXED — An unterminated quoted here-doc delimiter inside `${v=$( … )}`: the EOF error's line

    echo ${M=$(cat <<"\"
    x
    \
    )}

- bash: `S: line 1: unexpected EOF while looking for matching `"'`.
- curse (all tiers): `S: line 4: …`.

## F82. FIXED — `{v}<&10` with fd 10 closed: no error

    {v}<&10; echo st=$?

- bash: `S: line 1: 10: Bad file descriptor` and `S: redirection error: cannot duplicate
  fd: Bad file descriptor`, `st=1`.
- curse (all tiers): silent, `st=0`.

## F83. FIXED — An unterminated `$(` in a here-document body: earlier expansions not run; compiled: line 1

    cat <<F
    $(nosuch)$(

- bash: runs `$(nosuch)` first (`S: line 1: nosuch: command not found`), then `S: command
  substitution: line 4: unexpected EOF while looking for matching `)'`, status 127.
- curse (all tiers): no `nosuch` line, status 1; compiled also says `line 1:` for the EOF.

## F84. FIXED — Interp/tiered: the DEBUG trap misses a command after an async one

    trap 'echo D' DEBUG; x=1 & wait

- bash, curse compiled: `D` twice.
- curse interp / tiered / static: once.

## F85. FIXED — `disown` in a pipeline in a command substitution before a command word (reduced, root open)

    BASH_SOURCE=$(disown|while(())do c;done) p

- bash: only `p: command not found`.
- curse (all tiers): `disown: current: no such job` first. `x=$(disown | :)` agrees (both
  print it); reduced by ddmin in the container, not narrowed further.

## F86. FIXED — `declare -n BASH_ARGV["a b"]=x`: no error for the special array

    declare -n BASH_ARGV["a b"]=x

- bash: `S: line 1: declare: BASH_ARGV[a b]: reference variable cannot be an array`, status 1.
- curse (all tiers): silent, status 1. (`declare -n A["a b"]=x` agrees.)

## F87. FIXED — Interp/tiered: a redirection error of a group on the left of `||` loses `line N:`

    { :; } > "$x" || :

- bash, curse compiled: `S: line 1: : No such file or directory`.
- curse interp / tiered / static: `S: : No such file or directory`.

## Not curse bugs (campaign triage)

- `kill -8 $$` (any crash signal a script sends itself): the harness counts it as a crash.
- Unwaited `cat <(…) &` / coprocs / `>(read …)` racing the end of the script, the
  interleaving of `select`'s `#? ` prompt with async stderr, and how many lines an endless
  loop prints before the 5 s limit: NOISE. The per-exec pid namespace makes bash's
  `$!`/coproc pids small; cmp.sh masks `coproc [N:` now.

# Fix notes, F31–F52 (fix-fuzz3, merged 494327d)

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

# Fix notes, F53–F87 (fix-f53)

- F53–F55 FIXED — the class: every text the parser stores raw and re-reads while a command
  runs (${…} operands, subscripts, redirect targets, case patterns, arithmetic `$…` chunks,
  prompts, mail/env-file texts, the compiled tier's assoc keys) now goes through ONE guarded
  entry, parser.reword: a construct left open is an error part, never a raised Lua string.
  Each earlier fix (F2, F5, F48) had guarded one more site; `grep -nE "(parse_word|
  parse_default_quoted|parse_heredoc)\b" lua/*.lua` outside parser/emit now shows only
  pcall'd or reword'd reads (emit's compile-time reads go through EF.pword → no compiled
  form). Roots: `A=$((()))$(())` taken as one $((…)); ${x/PAT/REP} split on a `/` inside a
  nested ${…}/$(…)/`…` (skip_to_delim); a ${ nested inside $((…)) (bash's P_ARITH nests
  only $( ). test/cases/2749-reread-open-dolbrace.sh
- F56 FIXED — a DISCARD out of the EXIT trap ends the handler with the saved status (one
  runner for every EXIT trap, interp.run_trap_str); the compiled subscript error is a DISCARD
  too; `exit` in a sourced file runs the EXIT trap in the file's frame.
  test/cases/2750-exit-trap-subscript-discard.sh
- F57 FIXED — `do` in a for/select list is a word. test/cases/2758-for-in-do-word.sh
- F58 FIXED — Shell.new sets loopdepth 0. test/cases/2751-comsub-break-past-loops.sh
- F59 FIXED — select's menu: print_select_list's columns. test/cases/2759-select-menu-columns.sh
- F60 FIXED — <( )/>( ) bodies syntax-checked as the word is read.
  test/cases/2760-procsub-body-syntax-error.sh
- F61 FIXED on main before this work (by F36's vetting of every $name). F64 FIXED on main
  (by F40's trap line numbering); F80 FIXED on main (by F47; the reduced repro above lost the
  body line: `cat << A << B⏎x`). Pinned: test/cases/2776-fixed-by-fuzz3-pins.sh
- F62 FIXED — the for/select list block takes the loop's line. test/cases/2752-for-list-error-line.sh
- F63 FIXED — shift: the number, then the count. test/cases/2761-shift-numeric-first.sh
- F65 FIXED — a quoted/escaped word before `()` names a function (invalid when it runs).
  test/cases/2762-quoted-funcdef-name.sh
- F66 FIXED — ${#NAME[SUB]} looks at NAME first (rt.elem_len_pre). test/cases/2763-len-subscript-unset.sh
- F67 FIXED — compiled function definitions set $? 0. test/cases/2753-funcdef-status.sh
- F68 FIXED — ${#name} in a subscript isn't rewritten. test/cases/2754-arith-len-in-subscript-error.sh
- F69 FIXED — the whole operator token after `for NAME`. test/cases/2764-for-header-operator-token.sh
- F70, F83 FIXED — a here-document body's open $[ / `…` / $( is an error part at its place.
  test/cases/2765-heredoc-open-construct.sh
- F71, F87 FIXED — a compound's redirection error names bash's executing_line_number
  (rt.compound_line). test/cases/2766-compound-redirect-error-line.sh
- F72 FIXED — recursion level checked where bash's pushexp does, reported in the enclosing
  expression. test/cases/2767-arith-recursion-error-token.sh
- F73 FIXED — arithmetic faults show the expanded text. test/cases/2768-arith-error-expanded-text.sh
- F74 FIXED — test/cases/2769-arith-assign-non-variable.sh
- F75 FIXED — test/cases/2770-arith-subscript-dollar-backslash.sh
- F76 FIXED — rt.compiled_line for a $(…) in arithmetic text. test/cases/2755-arith-comsub-body-line.sh
- F77, F78 FIXED — test/cases/2771-dbracket-operator-tokens.sh
- F79 FIXED — test/cases/2756-for-list-break-in-loop.sh
- F81 FIXED — test/cases/2772-comsub-heredoc-delimiter-eof.sh
- F82 FIXED — test/cases/2773-varassign-dup-closed-fd.sh
- F84 FIXED — test/cases/2757-debug-trap-async.sh
- F85 FIXED — the root was not disown/pipelines: a prefix binding of a readonly/noassign
  variable is refused before its value expands (BASH_SOURCE=$(…) p ran nothing in bash).
  test/cases/2774-prefix-noassign-no-expansion.sh
- F86 FIXED — test/cases/2775-nameref-noassign-array.sh

# Overnight fuzz-night campaign (gram:tiered + gram:compiled, containerized), branch fuzz-night

Both found by campaign 1 (25 min, `gram:tiered`+`gram:compiled` in `fuzz-docker`), reduced by
hand, checked with `cmp.sh` in the container (bash 5.2.21 vs curse interp / compiled / tiered /
static) against the current main (bf1c58e, after the fix-f53 merge landed mid-campaign — a
third candidate from this same batch, an ambiguous-redirect error on a backgrounded compound
losing its `line N:` prefix, turned out to already be fixed by that merge's
2766-compound-redirect-error-line.sh and was dropped).

## F119. Compiled tier: a `for`/`select` loop assigning into a readonly special variable bypasses the readonly check and overwrites it

    old=$UID
    for UID in a b
    do
        :
    done
    echo "UID=$UID same=$([ "$UID" = "$old" ] && echo yes || echo no)"

- bash, curse interp/tiered/static: `S: line 2: UID: readonly variable` on the first
  iteration (the loop still runs), `UID=$old same=yes` (UID unchanged), status 0.
- curse compiled tier only: no error at all, and `UID` is silently overwritten by the loop
  (`UID=b same=no`) — the compiled tier's `for` loop doesn't check the readonly attribute
  before storing the iteration variable, so assigning into any readonly variable through a
  `for`/`select` list (not just a special one) escapes detection entirely and corrupts it.
  (gram:compiled queue; not touched by the for-loop line-attribution fixes in F62/F69/F79.)

## F120. `(( ${} ))`: bash's bad-substitution message keeps the subexpression's surrounding whitespace, curse trims it

    (( ${} ))

- bash: `S: line 1:  ${} : bad substitution` (the arithmetic subexpression text ` ${} `,
  spaces included, is echoed verbatim between "line 1:" and the message).
- curse (all tiers): `S: line 1: ${}: bad substitution` (trimmed to `${}`, no surrounding
  spaces) — a narrower case than F33 (`${}` alone): F33's fix only normalizes `${}` with no
  space before the following text, so `${} ` (a trailing space before the closer) still
  disagrees. (gram:tiered queue)

## Campaign 2 (gram:tiers + gram:parse, containerized), branch fuzz-night

## F121. Compiled tier: after an `eval`'d `trap ... ERR` sets a variable to `!`, using it unquoted as a command word runs the rest of the line as a negated pipeline instead of trying to execute a program named `!`

    eval "trap \"v='!'\" ERR"
    false
    $v echo hi

- bash, curse interp/tiered/static: `false` fires the ERR trap (`v='!'`); `$v echo hi`
  expands to the words `!` `echo` `hi`, run as a simple command named `!` (the value came
  from expansion, so `!`'s reserved-word negation never applies): `S: line 3: !: command
  not found`, status 127.
- curse compiled tier only: status 0, stdout `hi` — it executes `echo hi` with its status
  negated, i.e. it treats the *expanded* word `!` as bash's literal negation operator. The
  loop the fuzzer wrapped this in (a 120-iteration `for` re-registering the same trap) was
  incidental — reduces without it; needs the trap set through `eval`, not a literal
  top-level `trap` statement (a bare `trap "v='!'" ERR` at top level does not trigger it).
  (gram:tiers queue, the in-loop tier oracle: interp vs compiled vs tiered)

## Campaign 3 (gram:arith + gram:pexp, containerized), branch fuzz-night

Both targeted fuzzers (persistent AFL loop over curse's own forkserver child, README
"Targeted in-process fuzzers"); every candidate below was independently re-run through
`harness-plain` (one process, no loop) with a fresh `unshare` before being recorded, per
the campaign brief's fork-per-input verification requirement, since `FUZZ_TLOOP=1` isn't
wired through `docker/run.sh`'s env passthrough.

## F122. `${name[*]@A}` / `${name[@]@A}` on a plain scalar: bash uses the light `${@Q}`-style quoting, curse uses full `declare -p` output

    w='hello world'
    echo "${w[*]@A}"
    echo "${w[@]@A}"
    echo "${w@A}"

- bash: `w='hello world'` for all three (a `[*]`/`[@]` subscript on a non-array name makes
  `@A` fall back to the same lightweight `name='value'` form as the subscript-less
  `${w@A}`, not `declare -p`'s output).
- curse (all tiers): `declare -- w="hello world"` for the first two (the generic
  `declare -p`-style format, as if `w` were addressed by `declare -p w`), only agreeing
  with bash on the subscript-less `${w@A}`. Found by `gram:pexp` (this shape — any
  `${VAR[*]@A}`/`${VAR[@]@A}` on a scalar — was the majority of the campaign's ~140
  unbucketed pexp signatures, e.g. `${r+${w[*]@A}} ${lo:x}`); confirmed fresh with
  `harness-plain` before reduction, then reduced and reconfirmed with `cmp.sh` outside the
  target harness.

## Campaign 4 (gram:glob + gram:regex, containerized), branch fuzz-night

## F123. `BASH_REMATCH`'s `declare -p` drops one level of backslash-escaping for a captured value ending in a literal backslash

    shopt -s nocasematch xpg_echo
    s=$'x\x5c'
    re=$'\x5cw\x5b\x5ea\x5d'
    [[ $s =~ $re ]]
    declare -p BASH_REMATCH

(i.e. `s='x\'`, `re='\w[^a]'`: `\w` matches `x`, `[^a]` matches the backslash.)

- bash: `declare -a BASH_REMATCH=([0]="x\\")` — the captured value `x\` (2 chars),
  correctly double-escaped for `declare -p`'s re-parseable double-quoted form.
- curse (all tiers): `declare -a BASH_REMATCH=([0]="x\")` — only one backslash: not valid
  shell syntax fed back in (the trailing `\"` would escape the closing quote). Specific to
  a regex-captured value: a plain array literal with the same value
  (`a=('x\'); declare -p a`) prints correctly on both sides (`declare -a a=([0]="x\\")`),
  so the capture path stores/prints the match differently from a normal assignment.
  Found by `gram:regex`; confirmed fresh with `harness-plain`, then reduced with `cmp.sh`
  (a same-value simplification with `x\\` written directly, no `\w`/`[^a]` regex classes
  or `$'...\x..'` escapes, did not reproduce — those pieces matter, not just the value).
