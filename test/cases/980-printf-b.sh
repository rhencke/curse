# printf %b octal/escapes, \c stop, and format-reuse termination
printf '%b\n' '\141\0141'          # both octal forms -> aa
printf '%b\n' '\1\12\123'          # 1-3 octal digits
printf '%b\n' 'x\ty'               # standard escapes
printf '%b-AFTER\n' 'stop\chere'; echo "(after b-c)"

# printf format string: bare octal works, \c is literal
printf '\101\102\n'
printf 'a\cb\n'

# format reuse cycles while conversions consume args...
printf '[%s]' a b c; echo
# ...but a format that consumes no arguments does not loop forever
printf 'x' y z; echo '(done)'
printf 'hi\n' extra args

# %b with \c only aborts remaining output
printf '%s %b %s\n' one 'two\cthree' four; echo '(end)'

# float flags: # keeps the decimal point, 0 zero-pads even with precision
printf '%#.0f|%08.2f|%-8.2f|\n' 3 3.14 3.14
printf '%010.2e\n' 3.14

# error status: invalid number / invalid conversion abort with status 1
printf '%d\n' abc 2>/dev/null; echo "int-rc=$?"
printf 'AAA%zBBB\n' x 2>/dev/null; echo "fmt-rc=$?"
