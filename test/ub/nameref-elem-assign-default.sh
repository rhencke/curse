# docs/bash-ub.md: ${ref:=word} / ${ref=word} through a nameref to an array ELEMENT binds the
# nameref (assigning the element), then substitutes get_variable_value of the variable it
# landed on — the array's element 0. With no element 0 that is NULL, and quote_string(NULL)
# crashes (SIGSEGV). curse's pinned choice: the element's stored value is substituted.
# (With an element 0 bash's substitution is copied: test/cases.)
declare -n r='a[5]'
echo "[${r:=q}]"; declare -p a
b=([2]=k); declare -n s='b[7]'
echo "[${s=w}]"; declare -p b
declare -ai c; declare -n t='c[1]'
i=0; while [ $i -lt 150 ]; do unset 'c[1]'; x=${t:=i+1}; i=$((i + 1)); done; echo "$x"
eval 'unset d; declare -n u="d[3]"; echo "[${u:=e}]"'
