# declare -p with bundled attribute flags restricts the listing by attribute;
# declare/typeset reject an invalid target name with status 1.

scalar=hi
idx=(a b c)
declare -A assoc=([k]=v)
declare -i counter=7
declare -r locked=x

# -pa lists indexed arrays, -pA associative, -pi integers (bundled p + attr)
echo "[pa]"; declare -pa | grep -E ' idx='
echo "[pA]"; declare -pA | grep -E ' assoc='
echo "[pi]"; declare -pi | grep -E ' counter='
echo "[pr]"; declare -pr | grep -E ' locked='

# an indexed array must NOT show up under -pA and vice versa
echo "[pA-no-idx]"; declare -pA | grep -c ' idx=' || true
echo "[pa-no-assoc]"; declare -pa | grep -c ' assoc=' || true

# declare -p with a name still prints that one variable
declare -p scalar

# invalid identifier -> status 1, and processing continues past it
typeset bad/name 2>/dev/null; echo "invalid=$?"
declare ok1=1 2>/dev/null; echo "ok=$? ok1=$ok1"
