# break/continue with a run-time level (`break $n`, a bad count), and in a while/until
# CONDITION, compiled natively; a jump out of an if/while test or a non-final &&/||
# operand drops that test's errexit exemption (else `set -e` stays off afterwards);
# $LINENO in a for-in list is the `for` line; `for BAD in` is reported (posix: fatal).
n=2
for ((i=0;i<3;i++)); do for ((j=0;j<3;j++)); do echo "$i$j"; [ $j = 1 ] && break $n; done; done; echo "forc=$?"
for i in 1 2 3; do for j in a b; do echo "$i$j"; continue $n; echo no; done; done
until break $((n-1)); do echo x; done; echo "until=$?"
for i in 1 2; do while break 2; do echo x; done; echo no; done; echo "wb=$?"
for i in 1 2; do while continue 2; do echo x; done; echo no; done; echo "wc=$?"
for i in 1 2 3; do eval 'for j in a b; do echo $i$j; break $n; done'; echo no; done
for i in 1 2 3; do if break $n; then echo no; fi; done; echo "ifb=$?"
for i in 1 2; do echo $i; false || continue $n; echo no; done
f() { for i in 1 2 3; do echo f$i; break 0; done; echo "f0=$?"; }; f 2>&1
select s in a b; do echo "s=$s"; break $n; done <<< 1 2>/dev/null
for x in \
  $LINENO "$LINENO" $((LINENO)) $(echo $LINENO); do echo "line $x"; done
g() {
	for z in a \
		$LINENO; do echo "g $z"; done
}
g
trap 'echo "${FUNCNAME:-top}[$LINENO]"' DEBUG
h() { :; }
h
trap - DEBUG
for i.j in a; do echo no; done; echo "bad=$?"
( set -e; k=1
for i in 1 2; do if continue $k; then :; fi; done
for i in 1 2; do while break $k; do :; done; done
for i in 1 2; do true && break $k; done
r() { for i in 1; do if return 0; then :; fi; done; }
r
false
echo "not reached" ); echo "sub=$?"
set -o posix
for 1 in a; do :; done
echo "not reached"
