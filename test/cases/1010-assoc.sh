# associative arrays: (key value ...) init and arithmetic on numeric-key elements

# key/value sequence initialization
declare -A colors=(red 1 green 2 blue 3)
echo "seq=${colors[red]}/${colors[green]}/${colors[blue]}"

# [key]=value initialization still works
declare -A m=([alpha]=A [beta]=B)
echo "kv=${m[alpha]}/${m[beta]}"

# += append with key/value pairs
declare -A n=(a 1)
n+=(b 2 c 3)
echo "append=${n[a]}/${n[b]}/${n[c]}"

# arithmetic reads and writes on associative elements (numeric-looking keys)
declare -A A
(( A[5] = 10 ))
(( A[5] += 6 ))
echo "arith=${A[5]}"

# arithmetic on an empty cell defaults to 0
declare -A B
(( B[7] += 7 ))
echo "empty-cell=${B[7]}"

# reading an assoc element inside (( ))
declare -A C
C[0]=42
(( v = C[0] + 8 ))
echo "read=$v"

# element count
declare -A D=(x 1 y 2 z 3)
echo "count=${#D[@]}"

# associative subscripts in arithmetic are literal keys, not evaluated
declare -A K
K[foo]=7
(( kf = K[foo] ))
echo "name-key=$kf"
(( K[bar] = 3 * 4 ))
echo "name-write=${K[bar]}"
K["2+3"]=hit
(( kv = K[2+3] ))            # key is literally "2+3", not 5
echo "expr-key=$kv"
k=foo
(( ky = K[k] ))             # key is literally "k", not "foo"
echo "var-key=[$ky]"

# an indexed array still evaluates its subscript
idx=(0 0 0 0 0 0)
(( idx[2+3] = 88 ))
echo "indexed-eval=${idx[5]}"
