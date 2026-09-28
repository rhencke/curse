# After `for NAME` / `select NAME` a redirection operator or `;;` is bash's syntax error
# near the whole operator token (`>&`, `<<<`, `&>`, `;;`, a `<(…)` word), not its first
# character (fuzz F69).
e() { eval "$1"; echo "st $?"; }
e 'for x >&f'
e 'for x >f'
e 'for x <&f'
e 'for x >>f'
e 'for x &>f'
e 'for x <>f'
e 'for x >|f'
e 'for x <<<f'
e 'for x <<-f'
e 'select x >&f'
e 'for x ;; y'
e 'for x <(y)'
e 'for x; do echo $x; done'
i=0; while [ $i -lt 150 ]; do e 'for i >&2'; i=$((i + 1)); done 2>&1 | sort | uniq -c
