# printf: option terminator, argument cycling, # flag, integer parsing/clamping

# `--` ends options; format is reused while arguments remain
printf -- '-%s-%s-%s-\n' 'a b' 'x y'
printf -- '-%s-%s-\n' a b c d e

# -v captures into a variable; an invalid target name is an error (status 2)
printf -v cap '%d/%d' 6 7; echo "cap=[$cap]"
printf -v 'bad[' %s foo 2>/dev/null; echo "badtarget=$?"

# # (alternate form) prefixes non-zero octal/hex and keeps %g's trailing zeros
printf '[%#o][%#o]\n' 0 42
printf '[%#x][%#X]\n' 42 42
printf '[%g][%#g]\n' 3 3

# integer parsing: leading space ok, trailing junk is an error but emits the
# value parsed so far
printf '%d\n' ' -42'; echo "s=$?"
printf '%d\n' '3abc'; echo "s=$?"
printf '%d\n' 'xyz'; echo "s=$?"
printf '%d\n' ' +077'; echo "s=$?"

# overflow clamps (not wraps): %d saturates to the signed range, %u to unsigned
printf '%d\n' '18446744073709551615'
printf '%u\n' '18446744073709551616'
printf '%u %x\n' -1 -1
