# A syntax error in trap handler text is reported the way bash's parse_and_execute
# names its input: `NAME: TAG: line N:` — TAG "trap" (a signal's handler), "exit
# trap", "debug trap", "error trap", "return trap" (trap.c). A signal's and the EXIT
# trap's text count lines from 1 (SEVAL_RESETLINE); DEBUG/ERR/RETURN text counts on
# from the line the handler runs at. A $( … ) syntax error in a signal/DEBUG handler
# ends the shell (FORCE_EOF), status 2 — checked in a child shell.
exec 2>&1
trap 'if' USR1
kill -USR1 $$
trap 'echo )' ERR
false
trap - ERR
trap 'fi' DEBUG
:
trap - DEBUG
f() { :; }
g() { trap 'done' RETURN; :; }
g
trap - RETURN
trap 'echo ok;
then' ERR
false
trap - ERR
trap '. ./bad.sh; eval "fi"' USR2
printf 'echo (\n' > bad.sh
kill -USR2 $$
trap - USR2
h() { local i; for ((i=0; i<160; i++)); do trap 'esac' DEBUG; :; trap - DEBUG; done >hout 2>&1; sort hout | uniq -c; rm -f hout; }
h
for i in $(seq 160); do trap '((' ERR; false; trap - ERR; done 2>&1 | sort | uniq -c
printf 'trap "x=\\$(fi); echo in" DEBUG\necho after\n' > c1.sh
"$THIS_SH" c1.sh; echo "st=$?"
printf 'trap "x=\\$(fi)" USR1\nkill -USR1 $$\necho after\n' > c2.sh
"$THIS_SH" c2.sh; echo "st=$?"
rm -f bad.sh c1.sh c2.sh
trap 'if
then' EXIT
