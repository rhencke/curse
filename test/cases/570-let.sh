# let: evaluate arithmetic; status 1 iff the last expression is zero
let x=5
echo "x=$x status=$?"
let y=0
echo "y=$y status=$?"

# multiple expressions; status from the last
let "a = 3" "b = a * 2"
echo "a=$a b=$b status=$?"
let n=10 m=n-10
echo "n=$n m=$m status=$?"

# increment / compound assignment
let count=0
let count++
let count+=5
echo "count=$count"

# used as a condition
if let "x > 3"; then echo "x>3"; fi
let "x < 3" && echo "nope" || echo "x not <3"
