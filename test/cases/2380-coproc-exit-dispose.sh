# A coproc still unreaped when the shell exits is disposed then (after the EXIT trap): its
# NAME is unset, so a readonly NAME is reported at the line bash's reader stands on — the
# `exit`'s line, or the last line + 1 at end of input. Each probe is its own shell.
S=${THIS_SH:-bash}
n() { sed 's/^.*line \([0-9]*\): /line \1: /'; }
printf 'readonly r=1\ncoproc r { :; }\necho end\n' > p1.sh
printf 'readonly r=1\ntrap "echo trap" EXIT\ncoproc r { :; }\necho end\n' > p2.sh
printf 'readonly r=1\ncoproc r { :; }\necho end\nexit 3\n' > p3.sh
printf 'readonly r=1\ncoproc r { sleep 0.05; }\necho end\n' > p4.sh
printf 'readonly r=1\ncoproc r { :; }\nwait\necho st=$?\n' > p5.sh
for f in p1 p2 p3 p4 p5; do "$S" $f.sh 2>&1 | n; echo "$f st=${PIPESTATUS[0]}"; done
