# A variable holding expression TEXT that names a hot loop's counter: `x='i*2'; $((y+x))`.
# bash evaluates the text when it is read, so it sees the counter's current value. The
# compiled tier keeps hot integer variables in Lua registers and wrote them to the shell's
# variables only at sync points, so text evaluated at run time read a stale counter:
# `y=$((y+x))` over 150 rounds gave 0 compiled and 19800 tiered for bash's 22350 (fixes N1).
# Every form that evaluates text at run time — a value read in arithmetic, $(( $x )), [[ ]]
# and (( )) operands, let, subscripts, substrings, declare -i, a reference made by eval —
# in each loop kind, at the top level, in a function (its own `local` counter too) and in
# eval'd code; texts that assign (`i++`) must update the counter the loop goes on with.
# (Each loop has a counter of its own: one name's other uses must not keep it out of a
# register.)
# (every counter is set before any loop, so each can be held in a register)
a1=0; a2=0; a3=0; a4=0; a5=0; a6=0; a7=0; a8=0; a9=0; b1=0; b2=0; b3=0; b4=0; b5=0; b6=0; b7=0; b8=0; b9=0; c1=0; j=0; c2=0; c3=0; c5=0; c6=0; c7=0; c8=0; c9=0; d1=0; c4=0
y=0; x='a1*2'
while [ $a1 -lt 150 ]; do y=$((y + x)); a1=$((a1 + 1)); done; echo "while-test $y"
y=0; x='a2*2'
for ((a2 = 0; a2 < 150; a2++)); do (( y += x )); done; echo "forc (( )) $y"
y=0; x='a3*2'
until ((a3 >= 150)); do y=$(( $x + y )); ((a3++)); done; echo "until \$x $y"
y=0; x='a4*2'
while ((a4 < 150)); do [[ $x -gt 100 ]] && y=$((y + 1)); a4=$((a4 + 1)); done; echo "[[ \$x -gt ]] $y"
y=0; x='a5*2'
for ((a5 = 0; a5 < 150; a5++)); do [[ x -gt 100 && x -lt 250 ]] && y=$((y + 1)); done; echo "[[ name ]] $y"
y=0; x='a6*2'
for ((a6 = 0; a6 < 150; a6++)); do let "y += $x"; done; echo "let \$x $y"
y=0; x='a7*2'
for ((a7 = 0; a7 < 150; a7++)); do let "y += x"; done; echo "let name $y"
v3=(5 6 7)
y=0; x='a8%3'
for ((a8 = 0; a8 < 150; a8++)); do y=$((y + ${v3[x]})); done; echo "\${a[x]} $y"
y=0; x='a9%3'
for ((a9 = 0; a9 < 150; a9++)); do y=$((y + v3[x])); done; echo "a[x] $y"
s=abcdefg
y=0; x='b1%5'
for ((b1 = 0; b1 < 150; b1++)); do z=${s:x:1}; [ "$z" = c ] && y=$((y + 1)); done; echo "substring $y"
declare -i di
y=0; x='b2*2'
for ((b2 = 0; b2 < 150; b2++)); do di=$x; y=$((y + di)); done; echo "declare -i $y"
y=0; x='b3*2'
for ((b3 = 0; b3 < 150; b3++)); do if ((x > 50)); then y=$((y + 1)); fi; done; echo "if (( )) $y"
y=0; x='b4*2'
for ((b4 = 0; b4 < 150; b4++)); do case $((x % 4)) in 0) y=$((y + 1));; esac; done; echo "case \$(( )) $y"
y=0; ve=("b5*2")
for ((b5 = 0; b5 < 150; b5++)); do y=$((y + ve[0])); done; echo "element value $y"
y=0; x='b6*2'
for ((b6 = 0; b6 < 150; b6++)); do bb[x]=1; y=${#bb[@]}; done; echo "bb[x]= $y"
y=0; x='b7*2'
for ((b7 = 0; b7 < 150; b7++)); do y=$((y + $[x])); done; echo "\$[ ] $y"
y=0; x='(b8+1)*(b8+2)'
for ((b8 = 0; b8 < 150; b8++)); do y=$((y + x % 1000)); done; echo "nested text $y"
# texts that ASSIGN: to the counter itself, to another lifted variable
y=0; x='b9++'
for ((b9 = 0; b9 < 150; b9++)); do : $((x)); y=$((y + b9)); done; echo "counter++ text $y $b9"
y=0; x='j=c1*3'
for ((c1 = 0; c1 < 150; c1++)); do : $((x)); y=$((y + j)); done; echo "j= text $y"
y=0; x='y=y+c2'
for ((c2 = 0; c2 < 150; c2++)); do : $((x)); done; echo "y= text $y"
# a function reading text (the loop's counter lives in the caller's frame)
y=0; x='c3*2'
f() { y=$((y + x)); }
for ((c3 = 0; c3 < 150; c3++)); do f; done; echo "function reads $y"
g() { local k=0 t=0; xk='k*2'; while ((k < 150)); do t=$((t + xk)); k=$((k + 1)); done; echo "local counter $t"; }
g; g
h() { local n; c4=0; y=0; x='c4*2'; x3='c4%3'; for ((c4 = 0; c4 < 150; c4++)); do y=$((y + x)); (( y += x3 )); done; echo "in function $y"; }
h; h
y=0; x='c5*2'
eval 'for ((c5 = 0; c5 < 150; c5++)); do y=$((y + x)); done; echo "eval loop $y"'
y=0; x='c6*2'
for ((c6 = 0; c6 < 150; c6++)); do eval 'y=$((y + x))'; done; echo "eval body $y"
y=0; x='c7*2'
for ((c7 = 0; c7 < 150; c7++)); do z=$(echo $((x))); y=$((y + z)); done; echo "\$( ) $y"
y=0; x='c8*2'
for ((c8 = 0; c8 < 150; c8++)); do printf -v t '%d' $((x)); y=$((y + t)); done; echo "printf -v $y"
# a reference made at run time (eval): reads and writes go to the counter
y=0; eval 'declare -n rf=c9'
for ((c9 = 0; c9 < 150; c9++)); do y=$((y + rf)); done; echo "nameref read $y"
y=0; eval 'declare -n rg=d1'
for ((d1 = 0; d1 < 150; d1++)); do rg=$((rg + 1)); y=$((y + d1)); done; echo "nameref write $y $d1"
