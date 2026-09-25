# parse.y: grammar and lexer corners -- reserved-word recognition, compound-command
# variants (function bodies, case pattern lists, arith for), which token a syntax error
# reports (and its $'..' quoting), here-doc delimiter rules, alias/reserved-word order,
# extglob as a parse-time option, parse errors inside $( ) and compound assignments.
# Every syntax error runs through eval so the file keeps going.
n() { sed -e 's/^[^:]*: //' -e 's/line [0-9]*/line N/g' | cat -v; }
t() { eval "$1" 2>&1 | n; echo "st=${PIPESTATUS[0]}"; }

# grammar bash rejects (the reported token matters)
for c in 'for x in a b; echo; done' 'echo a | ! true' 'case a in a|) echo e;; esac' \
	'case a in |a) echo e;; esac' 'case a in ) echo e;; esac' 'case a in a) echo e;;; esac' \
	'function f {echo x; }' 'echo x; {' 'coproc' 'coproc a=b { :; }' 'function' 'select' \
	'for ((;;)' 'case x in (a|b) echo y;; (c' 'case x in a) ;; b' 'case x in x|y|(z) echo x;; esac' \
	'echo (a)' 'case a' 'for (( i=0 i<1 ))' 'echo `echo "\`"`'; do
	t "$c"
done
# the offending token is shown $'..'-quoted when it holds control characters
t $'case a b\x02 in esac'
t $'case a b\x1b in esac'
t $'(:) \'q\x7f\''

# grammar bash accepts: any compound command is a function body; reserved words are
# only reserved where a command starts, and an assignment word is never reserved
t 'if=1; echo $if'
t 'f() if true; then echo f4; fi; f'
t 'f() for i in a; do echo f5; done; f'
t 'f() [[ 1 ]]; declare -f f'
t 'f() ((1)); declare -f f'
t 'function f [[ 1 ]]; f && echo fc'
t 'function f case a in a) echo f6;; esac; f'
t 'function if { echo fif; }; declare -F if'
t 'for ((i=0;i<2;i++)) { echo $i; }'
t 'for i do echo $i; done'
t 'case a in a) echo 1;& b) echo 2;;& *) echo 3;; esac'
{ time -p; } 2>&1 | cut -d' ' -f1

# aliases: in normal mode reserved words are checked AFTER alias expansion (so `!' and
# `if' can come from an alias); in posix mode BEFORE (a reserved word is never aliased)
shopt -s expand_aliases
alias bang='!'
t 'bang false && echo neg'
alias if='echo aliased-if'
t 'if x'
unalias if
( set -o posix; alias while='echo W'; eval 'while false; do :; done; echo pw' ) 2>&1 | n

# extglob is decided when the line is PARSED
t 'echo @(ab)'
t 'case ab in @(ab)) echo m6;; esac'
t 'f() { shopt -s extglob; echo @(ab); }; f'
shopt -s extglob
t 'echo @(ab|ac'
shopt -u extglob

# statuses: a malformed compound assignment fails eval with 1 (the shell goes on, a
# subshell ends); a parse error inside $( ) ends a non-interactive shell with 1
t 'a=(1 2'
t 'a=(1 (2) 3)'
( eval 'a=(1 (2) 3)'; echo after ) 2>&1 | n; echo "sub=${PIPESTATUS[0]}"
( eval 'echo $(if)'; echo notreached ) 2>&1 | n; echo "sub=${PIPESTATUS[0]}"
( set -o posix; eval 'a.b() { :; }'; echo "posix fname st=$?" ) 2>&1 | n; echo "sub=${PIPESTATUS[0]}"

# here-document delimiters: inside "..." a backslash before F is kept; the delimiter
# line must match exactly (no trailing blanks); an empty quoted delimiter; `<<\' newline
t 'cat <<"E\F"
lit $HOME
E\F
echo after-EF'
t 'cat <<END
x
END '
cat <<""
empty delim

cat <<\
EOF
cont delim
EOF

# $"..." inside a double-quoted ${..}; posix: no $'..' inside a double-quoted ${..}
t 'echo "${x:-$"t"}" ${x:-$"u"}'
( set -o posix; eval 'echo "${x:-$'"'"'\t'"'"'}"' )
