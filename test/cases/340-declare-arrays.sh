# declare -a with a literal
declare -a fruits=(apple banana cherry)
echo "count: ${#fruits[@]}"
echo "all: ${fruits[@]}"
echo "one: ${fruits[1]}"

# declare -A with literal [key]=val elements
declare -A ages=([alice]=30 [bob]=25)
echo "alice: ${ages[alice]}"
echo "acount: ${#ages[@]}"

# local array inside a function
build() {
  local -a nums=(10 20 30)
  local total=0
  for n in "${nums[@]}"; do total=$((total + n)); done
  echo "local total: $total"
}
build
echo "leaked: [${nums[@]}]"

# append via declare-arg form is uncommon; use element/array
declare -a xs=(1 2)
xs+=(3 4)
echo "xs: ${xs[@]}"

# readonly assignment (not enforced)
readonly RO=fixed
echo "ro: $RO"
