greet() {
  echo "hello, $1"
}
greet world
greet "dear friend"

sum() {
  local total=0
  for n in "$@"; do
    total=$((total + n))
  done
  echo "sum=$total"
}
sum 1 2 3 4 5

count() {
  echo "got $# args"
}
count a b c

describe() {
  if [ "$1" -gt 0 ]; then
    echo positive
    return 0
  fi
  echo nonpositive
  return 1
}
describe 5
echo "rc=$?"
describe -3
echo "rc=$?"
