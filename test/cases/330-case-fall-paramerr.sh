# ;& falls through to the next clause's body
classify() {
  case "$1" in
    a) echo "is a" ;&
    b) echo "a or b" ;;
    c) echo "is c" ;;
  esac
}
classify a
echo "---"
classify b
echo "---"
classify c
echo "==="

# ;;& keeps testing later patterns
describe() {
  case "$1" in
    *e*) echo "has e" ;;&
    h*)  echo "starts h" ;;&
    *o)  echo "ends o" ;;
  esac
}
describe hello
echo "---"
describe world

# ${!name} indirect
target=greeting
greeting="hi there"
echo "indirect: ${!target}"

# ${x:?} with value present (no error)
set_ok=value
echo "ok: ${set_ok:?should not fire}"

# ${x:-} still works
echo "default: ${unset_var:-fallback}"
