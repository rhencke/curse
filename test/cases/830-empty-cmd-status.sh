# exit-code truncation, empty commands, and backtick == $()

# return/exit codes are one byte
f() { return 257; }; f; echo "ret257=$?"
g() { return 256; }; g; echo "ret256=$?"
h() { return -1; }; h; echo "retneg=$?"

# $? stays visible during a command's own expansion
false; echo "q1=$?"; echo "q2=$?"
false; x=$?; echo "assign=$x"; echo "after=$?"

# assignment status: 0 unless a command sub in the RHS ran
a=5; echo "a=$?"
b=$(false); echo "b=$?"
c=$(true); echo "c=$?"

# empty command (all words expand away) takes the last command sub's status
$(exit 42); echo "e42=$?"
$(true); echo "et=$?"
$(false); echo "ef=$?"
$(exit 7) $(exit 9); echo "pair=$?"
true $(false); echo "true_sub=$?"

# an empty command name is "command not found", not a crash
'' 2>/dev/null; echo "empty=$?"
e=; $e; echo "emptyvar=$?"

# backtick command substitution splits and globs exactly like $()
set -- `true`; echo "btcount=$#"
set -- `echo one two three`; echo "btwords=$#"
`false`; echo "btstatus=$?"
r=`echo hello`; echo "btassign=$r"
if `true`; then echo "btif=TRUE"; fi
