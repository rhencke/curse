# Arithmetic honors `set -u`: referencing an unset variable (or array element)
# in an arithmetic context is a fatal error, exactly like a plain `$unset`.

# With nounset OFF, an unset name reads as 0.
echo "off: $(( z + 1 ))"
a=(10 20)
echo "off-elem: $(( a[5] + 1 ))"

# An empty-but-SET variable is fine under nounset (it's 0, not unbound).
e=
set -u
echo "empty-set: $(( e + 5 ))"

# An unset variable in arithmetic aborts (status 1 from a script); isolate each
# in a subshell so the script keeps going and we can observe the status.
( x=$(( y + 5 )); echo "unreached x=$x" ) 2>/dev/null
echo "arith_unset=$?"

( (( undef++ )); echo "unreached" ) 2>/dev/null
echo "incr_unset=$?"

( echo "$(( undef2[0] ))" ) 2>/dev/null
echo "elem_unset=$?"

echo done
