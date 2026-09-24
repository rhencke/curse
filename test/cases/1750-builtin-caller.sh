# builtin / caller / : true false, from bash's builtins/builtin.def, caller.def,
# colon.def: `builtin` with no name or `--` succeeds, takes no options, refuses
# a non-builtin — including one disabled with `enable -n` — and bypasses
# functions; caller is status 1 outside a function, prints "LINE FILE" or
# "LINE FUNC FILE" per frame, 1 past the last frame, and a non-number is an
# invalid number plus usage (2); `:`/true/false ignore their arguments.
e() { sed 's/^.*line [0-9]*: //'; }
builtin; echo "none st=$?"
builtin --; echo "dd st=$?"
builtin -- echo dd-echo
builtin -x 2>&1 | e; echo "st=${PIPESTATUS[0]}"
builtin nosuch 2>&1 | e; echo "st=${PIPESTATUS[0]}"
builtin ls 2>&1 | e; echo "st=${PIPESTATUS[0]}"
echo() { printf 'fn-echo\n'; }; builtin echo real-echo; echo x; unset -f echo
enable -n printf; builtin printf '%s\n' disabled-but-builtin 2>&1 | e; printf 'x\n' 2>/dev/null | head -1; enable printf
builtin builtin echo nested
cd() { echo fn-cd; }; builtin cd /; pwd; unset -f cd; cd - >/dev/null
f() { builtin return 3; echo no; }; f; echo "ret st=$?"
builtin : ; echo "colon st=$?"; builtin false; echo "false st=$?"
: a b c; echo ": st=$?"; true --help; echo "true st=$?"; false x; echo "false st=$?"
caller; echo "top caller st=$?"
caller 0; echo "top caller0 st=$?"
g() { caller; caller 0; echo "g0 st=$?"; caller 1; echo "g1 st=$?"; caller 5; echo "g5 st=$?"; }
h() { g; }
g | sed "s|[^ ]*bi.sh|SELF|; s|[^ ]*run.lua|SELF|"
h | sed "s|[^ ]*bi.sh|SELF|g; s|[^ ]*run.lua|SELF|g"
k() { caller x 2>&1 | e; echo "x st=${PIPESTATUS[0]}"; caller -x 2>&1 | e; echo "-x st=${PIPESTATUS[0]}"; caller -- 0 | sed "s|[^ ]*bi.sh|SELF|; s|[^ ]*run.lua|SELF|"; caller ' 0 ' | sed "s|[^ ]*bi.sh|SELF|; s|[^ ]*run.lua|SELF|"; caller -1; echo "neg st=$?"; }
k
printf 'sf() { caller 0; caller 1; }\nsf\n' > s.sh; m() { . ./s.sh; }; m | sed "s|[^ ]*bi.sh|SELF|g; s|[^ ]*run.lua|SELF|g"
