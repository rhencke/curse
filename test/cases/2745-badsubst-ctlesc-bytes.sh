# A bad substitution names the word as the parser stored it, where each \001 (CTLESC) and
# \177 (CTLNUL) byte is quoted by a \001 (read_token_word): printed raw, `${a<01>}` shows
# the byte doubled and `${a<7f>}` as <01><7f> — in "…", unquoted, `${!…}`, `${#…}`, and a
# "no closing" message alike (fuzz F46).
show() { sed 's/^[^:]*: line [0-9]*: //' | od -An -c; }
eval $'echo "${a\001}"' 2>&1 | show
eval $'echo ${a\001}' 2>&1 | show
eval $'echo "${a\177}"' 2>&1 | show
eval $'echo ${a\177b} "${!a\001}" "${#a\001}"' 2>&1 | show
eval $'echo "${a[\001}"' 2>&1 | show
eval $'x=\001; echo "${a$x}"' 2>&1 | show
f() { eval $'echo "${f\001g}"'; }; f 2>&1 | show
printf 'echo "${a\001}"\n' > s2745.sh; . ./s2745.sh 2>&1 | show
trap 'eval $'"'"'echo "${t\177}"'"'"'' USR1; { kill -USR1 $$; } 2>&1 | show; trap - USR1
i=0; while [ $i -lt 150 ]; do (eval $'echo "${h\001}"'); i=$((i + 1)); done 2>&1 | sort | uniq -c | show
rm -f s2745.sh
