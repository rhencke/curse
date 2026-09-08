# array subscripts inside arithmetic
a=(10 20 30 40)
echo $(( a[0] + a[1] ))
echo $(( a[2] * 2 ))
i=3
echo $(( a[i] ))
echo $(( a[i-1] ))

# increment/decrement array elements
(( a[0]++ ))
(( ++a[1] ))
(( a[2] += 5 ))
echo "arr: ${a[*]}"

# assign to an element via arithmetic
(( a[5] = a[0] * 10 ))
echo "a5=${a[5]}"

# scalar treated as element 0
s=42
echo $(( s[0] + 1 ))

# nested / double subscript
idx=(0 1 2)
echo $(( a[idx[1]] ))

# undefined element is 0
echo $(( undef[3] + 7 ))

# comma operator
echo $(( 1, 2, 3 ))
x=$(( (5, 10) ))
echo "x=$x"

# assoc-free dynamic index expression
declare -a nums=(100 200 300)
n=2
(( nums[n] = nums[n] + 1 ))
echo "nums: ${nums[*]}"
