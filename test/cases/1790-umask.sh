# umask, from bash's builtins/umask.def: display (%04o, -S symbolic, -p reusable),
# octal modes (out of range / non-octal are errors, the mask unchanged), symbolic
# clauses (who agou, op + - =, perms rwx, comma lists, bad operators/characters),
# -S with a mode prints the new mask, options stop at the first operand or `--`.
e() { sed 's/^.*line [0-9]*: //'; }
t() { ( umask 022; umask "$@" 2>&1; echo "st=$? now=$(umask) $(umask -S)" ) | e; }
t
t -S
t -p
t -pS
t -Sp
t 0
t 777
t 0777
t 1777
t 7777
t 17777
t 08
t 0x1
t 123abc
t ''
t u+w
t g-rwx
t o=
t a=rx
t u=rwx,g=rx,o=
t ug=r
t =
t u=
t +x
t -w
t u=g
t u
t u*w
t u+q
t 'u+w,'
t ',u+w'
t 'u+w,,g+w'
t 'o+rwxrwx'
t -S 027
t -S u=rwx,go=
t -x
t -- 027
t 027 033
t 027 -S
