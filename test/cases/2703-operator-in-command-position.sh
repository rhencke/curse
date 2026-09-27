# A control operator where a command begins is bash's "syntax error near unexpected token"
# naming the whole operator token: `;&` and `;;&` are tokens of their own (outside a case
# clause they end no statement: `true;&echo x` is near `;&', not `&'), and a case clause
# body may not begin with one (`case 0 in x)|0` is near `|'). curse split `;&` into `;` +
# `&`, and for the case body indexed a nil command — its Lua error text was reported as the
# syntax error (fuzz F3, F7).
S=${THIS_SH:-bash}
t() { "$S" -c "$1" 2>&1 | sed 's/^[^:]*: //'; echo "rc=${PIPESTATUS[0]}"; }
t 'case 0 in $())|0'
t 'case 0 in x) |0;; esac'
t 'case 0 in x)&0'
t 'case 0 in x)&&0'
t 'case 0 in x)||0'
t 'case 0 in x)|&0'
t 'true;&echo x'
t 'true;;&echo x'
t 'true ;& echo x'
t '{ true;& }'
t 'if true;& then :; fi'
t 'while :;& do :; done'
t 'echo a | ;& b'
t 'echo a || ;;& b'
t 'f() { echo;& }'
case x in x) echo a;& y) echo b;;& *) echo c;; esac
eval 'true;&echo x'; echo "eval st=$?"
eval 'case 0 in x)|0'; echo "eval st=$?"
f() { eval 'case 1 in 1) ;& 2)&x;; esac'; echo "fn st=$?"; }; f
trap 'eval "true;;&"; echo "trap st=$?"' USR1; kill -USR1 $$
r=; for ((i = 0; i < 150; i++)); do eval 'true;&x' 2>/dev/null; r=$r$?; done; echo "loop ${#r} ${r//2/}."
