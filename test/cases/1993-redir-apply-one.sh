# Redirections the compiled tier applies through rt.redir_apply_one (a named fd {v}>,
# fd moves, dups to an expanded fd, cmdsub/arith/brace targets, expanding heredocs),
# and <()/>() drained after the command (or redirected compound) that made them.
cd "$(mktemp -d)"
exec {fd}>out1; echo hi >&$fd; exec {fd}>&-; cat out1
echo moved 3>&1 4>&3-
f=o2; echo x > ${f}$((1+1)); cat o22
echo y > $(echo o3); cat o3
cat <<EOF2
a $(echo b) ${u:-"c d"} ${#f}
EOF2
i=0; while (( i < 2 )); do echo line$i > f$(echo $i); i=$((i+1)); done; cat f0 f1
echo z > {a,b} ; echo st=$?
echo w 2>&1 >/dev/null
read v <<< "$(echo here string)"; echo $v
g() { local n; exec {n}<out1; read -u $n line; echo "g:$line"; exec {n}<&-; }; g
echo tofd >&2- 2>/dev/null; echo st=$?
cat <(echo ps1) <(echo ps2)
for k in 1 2; do exec {w}>>out1; echo k$k >&$w; exec {w}>&-; done; cat out1
# the redirections don't see the command's prefix bindings
for i in 1; do IFS=/ read m v k < <(echo a/b/c); echo $m:$v:$k; done
IFS=: read a b c < <(echo x:y:z); echo $a-$b-$c
