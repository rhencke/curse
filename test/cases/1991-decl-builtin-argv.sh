# Declaration builtins (export/declare/typeset/readonly/local) whose words the
# compiled tier used to hand to the interpreter: an assignment word expands in
# assignment context (no split/glob; rt.assign_word when emit_word can't render
# it), other words split and glob, then b_export/b_local run on the argv — in a
# function with calldepth set so declare/typeset/local localize.
set -- a "b c" d
f() {
  typeset -a a=(x y)
  typeset IFS=,
  typeset a1="${a[@]} ${a[*]} $@ $* ${@} ${*}"
  typeset a2=${a[@]}\ ${a[*]}\ $@\ $*\ ${@}\ ${*} a3 a4
  local -r r=5
  declare -i n=2+3 m
  local s=$(echo 1 2) t=*.sh
  declare -p a1 a2 r n s t a3
  export E1=${a[@]}
  readonly RO=$1
  echo "$E1" $RO
  local w=${1:+"$@"}; echo "w=$w"
}
f p "q r"
declare -p a1 2>/dev/null || echo not global
declare -i g=4*4 h=${1:+"$@"}
declare -p g
export XX=${u-"$@"}; echo "$XX"
g2() { local IFS=: ; local v=$*; echo "$v"; local -i k=${#v}*2; echo k=$k; }
g2 p q
g3() { local -a names; local -A m; local cnt=${#BASH_ARGV}; declare -r c=${1:-def}; echo "$c" $cnt; }
g3; g3 given
