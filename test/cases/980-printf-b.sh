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
