# An error expanding a `for`/`select` word list is reported at the loop's own line, not at
# the line of its `do` body: the compiled tier wrote the list's block after compiling the
# body, so the block took the body's last line (fuzz F62). A later error's line then drifts
# as bash's does after an aborted multi-line command.
for a in $(( 1 ? : 3 ))
do echo in; done
echo st=$?
select a in x $(( 1 ? : 4 ))
do break; done <<< 1
case $(( 1 ? : 5 )) in
x) echo x;; esac
f() { for a in 1 $(( 1 ? : 6 ))
do echo in; done; }
f
eval 'for a in $(( 1 ? : 7 ))
do echo in; done'; echo "eval $?"
trap 'for a in $(( 1 ? : 8 ))
do echo in; done' USR1; kill -USR1 $$; trap - USR1
for i in 1 2; do for a in $(( 1 ? : 9 ))
do echo in; done; done
( while [ ${n:=0} -lt 150 ]; do n=$((n+1)); ( for a in $(( n ? : 10 ))
do :; done ); done ) 2>&1 | sort | uniq -c
