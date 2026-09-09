#!/usr/bin/env bash
# A deterministic, feature-heavy script: if bash and curse agree here (output +
# files written), the harness itself is sound.
set -u

# arithmetic, loops, arrays
declare -a nums=()
for ((i = 1; i <= 10; i++)); do nums+=($((i * i))); done
echo "squares: ${nums[*]}"
echo "count=${#nums[@]} last=${nums[-1]}"

# string ops
s="Hello, World"
echo "upper=${s^^} lower=${s,,} len=${#s}"
echo "slice=${s:7:5} strip=${s#Hello, } sub=${s//o/0}"

# associative array + sorted iteration
declare -A ages=([alice]=30 [bob]=25 [carol]=35)
for k in $(printf '%s\n' "${!ages[@]}" | sort); do
  echo "$k is ${ages[$k]}"
done

# functions, locals, return status
sum() { local t=0 n; for n in "$@"; do t=$((t + n)); done; echo "$t"; }
echo "sum=$(sum 1 2 3 4 5)"

# case, conditionals, test
for x in apple 42 ""; do
  if [[ -z $x ]]; then echo "empty"
  elif [[ $x =~ ^[0-9]+$ ]]; then echo "number: $x"
  else echo "word: $x"; fi
done

# here-doc, redirection, and file writes (exercises the fs diff)
cat > out.txt <<EOF
line1 $((2 + 2))
line2 ${s}
EOF
printf 'a\nb\nc\n' | sort -r > sorted.txt
wc -l < out.txt

# read + IFS
echo "x:y:z" | { IFS=: read a b c; echo "read: $a/$b/$c"; }

# param expansion edge cases
u=
echo "default=${u:-fallback} alt=${u:+set}"
echo "done, exit ok"
