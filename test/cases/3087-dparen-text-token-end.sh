# A `$((` that is no `$(( … ))` is still read with parse_matched_pair's arithmetic rules
# (P_ARITH: a `${` nests nothing), so the word ends where those balance it: `$(( ${x:-)} ))`
# is the word `$(( ${x:-)} )` then a `)` — a syntax error. The text is a command
# substitution parsed only when it runs: in "…" its syntax error is "command substitution:
# line N", and the shell goes on. curse read the whole $( … ) (leftovers M3).
e() { eval "$1"; echo "st $?"; }
e 'echo $(( ${x:-)} ))'
e 'x=$(( ${x:-)} ))'
e 'echo $(( ${x:-)} )x)'
e 'echo $((case x in x) echo y;; esac) )'
e 'echo "$(( ${x:-)} ))"'
e '( echo $((case x in x) echo y;; esac) )'
e 'echo $((case x in (x) echo y;; esac) )'
e 'echo $((echo a) ); echo $((echo b)|cat)'
e 'echo $(( ${x:-3} + 1 ))'
e 'f() { echo $(( ${x:-)} )); }'
f() { echo "[$(( ${x:-)} ))]"; echo "f $?"; }
f
i=0; while [ $i -lt 150 ]; do e 'echo "$(( ${x:-)} ))"'; i=$((i + 1)); done 2>&1 | sed 's/^.*line [0-9]*: //' | sort | uniq -c
