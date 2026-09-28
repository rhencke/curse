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
