# More of print_cmd.c: a `>&N` target that fits no int is a WORD (printed without the
# default fd, as written) while one that fits is a NUMBER (`>&007` is `1>&7`); an array
# literal given to a declaration builtin is rebuilt (`(x y)`) as an assignment's is; a
# <( … ) / >( … ) body is re-printed like a $( … )'s; a nested function whose body ends in
# a here-document still gets its `;`; a for (( )) slot keeps its newlines (only blanks are
# trimmed); `x[1]=( … )` keeps its subscript; a $( … ) body's here-document ended by
# `EOF  )` prints as bash reads it; and a [[ ]] word read twice is printed as written
# (fuzz F98).
f() { echo d >&4294967297; echo e >&2147483647; echo g 2>&4294967297; echo >&007; echo <&007; echo 3>&007-; echo <&2147483648; declare -a b=(  x	 y  ); local c=( 1
 2 ); cat <(case ok in ok) echo p;; esac) >(cat >out); exec 3> >(cat >>lines); }
declare -f f
g() {
  h() { cat <<E
x
E
}
  ( arr[1]=(w) ); x[2]=(a b)
  for ((i=0;
  i<1;
	  i++ )); do :; done
  z=$(cat <<EOF
hey
EOF  )
  [[ 1 -lt [\[:a:\]] ]]; [[ 1 -lt [[:a:]] ]]
}
declare -f g 2>&1
i=0; while [ $i -lt 150 ]; do eval 'n() { [[ 1 -lt [\[:a:\]] ]]; [[ 1 -lt [[:a:]] ]]; echo >&4294967297; }'; declare -f n; i=$((i + 1)); done | sort | uniq -c
