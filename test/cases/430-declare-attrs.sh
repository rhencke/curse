# declare -i: arithmetic evaluated on assignment
declare -i n=3+4
echo "n=$n"
n=10*2
echo "n=$n"
n+=5
echo "n after +=: $n"
n=n+1
echo "n after n+1: $n"

# a non-integer stays a literal string
plain=3+4
echo "plain=$plain"

# turning on -i does NOT re-evaluate an existing value (only future assigns)
val="6/2"
declare -i val
echo "val=$val"

# -l / -u force case on assignment
declare -l low
low="MixedCase"
echo "low=$low"
declare -u up
up="MixedCase"
echo "up=$up"

# -u also applies to +=
up+="more"
echo "up+=: $up"

# local -i inside a function
adder() {
  local -i sum=0
  sum+=5
  sum+=10
  echo "sum=$sum"
}
adder

# integer division truncates like bash arithmetic
declare -i q=17/5
echo "q=$q"
