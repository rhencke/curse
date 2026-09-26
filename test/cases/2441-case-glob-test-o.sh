# [[ -o OPT ]] and case patterns only the shared pattern expander takes ("$@", ~, a
# ${…} operator reading a loop counter held natively) — compiled through the runtime
set -e
[[ -o errexit ]] && echo on
[[ -o nounset ]] || echo off
[[ ! -o bogus ]] && echo bogus-off
set +e
for ((i = 0; i < 3; i++)); do
	case x$i in x"$i") echo "q$i" ;; *) echo no ;; esac
	case $i in "$@") echo at ;; ~) echo tilde ;; $((i))) echo arith$i ;; esac
done
for ((i = 0; i < 3; i++)); do
	case $i in "${@:-$i}"x) echo at ;; $(echo 1)) echo one ;; ~) echo tilde ;; "$i"*) echo q$i ;; esac
done
