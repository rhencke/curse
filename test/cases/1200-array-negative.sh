# negative array subscripts count from the end; out-of-range is a bad subscript;
# a plain reference to an array is ${name[0]}, so an empty array is "unset".

a=(x y z w)
a[-1]=LAST
a[-2]=SECOND
echo "1:${a[@]}"
echo "2:${a[-1]} ${a[-2]} ${a[-4]}"

# assigning a negative index that reaches before the start fails (status 1).
# (The status echo goes on its own line: bash aborts the rest of a `;`-list
# after a bare-assignment error, a quirk we don't replicate.)
b=()
b[-1]=oops
echo "3:s=$?"
b[-5]=oops
echo "4:s=$?"

# unset with an out-of-range negative index fails too
c=(1)
unset -v 'c[-2]'; echo "5:s=$?"
d=(p q r)
unset -v 'd[-1]'; echo "6:${d[@]} s=$?"

# a plain reference to an array is element 0 for the -/+ operators
e1=(); e2=("" x); e3=(first second)
echo "7:${e1-UNSET} | ${e1:-EMPTY} | ${e1+PLUS}"
echo "8:${e2-UNSET} | ${e2+PLUS}"
echo "9:${e3-UNSET} | ${e3+PLUS}"

# a sparse array without index 0 is unset for a plain reference
declare -a f=([5]=hi)
echo "10:${f-NOZERO} | ${f+PLUS}"
