# printf numeric parsing: bases, char code, 64-bit, # flag
printf '%d\n' 0x1f
printf '%d\n' 010
printf "%d\n" "'A"
printf '%d %d\n' 42 -5
printf '%+d % d\n' 7 7
printf '%u\n' 42
printf '%x %X\n' 255 255
printf '%o\n' 8
printf '%#x %#o %#X\n' 255 8 255
printf '%d\n' 9999999999
printf '%d\n' 0xffffffff
printf '%d\n' '  16'

# dynamic width / precision via *
printf '[%*d]\n' 5 42
printf '[%-*d]\n' 5 42
printf '[%.*f]\n' 2 3.14159
printf '[%*.*f]\n' 8 3 2.5

# floating point
printf '%f\n' 3.14159
printf '%.2f\n' 3.14159
printf '%.0f\n' 2.7
printf '[%8.2f]\n' 3.5
printf '[%-8.2f]\n' 3.5
