# ${var@a} expands to the variable's attribute letters (bash's order a A i l n r u x)

arr=(one two)
echo "1:${arr@a}"

declare -r rarr=(one two)
echo "2:${rarr@a}"

declare -rx PP=hi
echo "3:${PP@a}"

declare -A m=([k]=v)
echo "4:${m@a}"

declare -i n=5
echo "5:${n@a}"

declare -l lower=WORD
echo "6:${lower@a} [$lower]"

# a plain scalar has no attribute letters
plain=x
echo "7:[${plain@a}]"

# an element reference reports the array's own attributes
a=(1 2 3)
echo "8:${a[0]@a} | ${a@a}"

# an unset variable yields nothing
echo "9:[${nope@a}]"

# combined attributes come out in order
declare -aix combo=(1 2)
echo "10:${combo@a}"
