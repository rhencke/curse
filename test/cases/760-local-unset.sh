# `local x` declares but does not set the variable
g=global
f() {
  local x
  echo "x default: [${x-UNSET}]"
  [[ -v x ]] && echo "x is -v" || echo "x not -v"
  x=assigned
  echo "after: [${x-UNSET}] -v=$([[ -v x ]] && echo y || echo n)"
}
f
echo "outside: [${x-nofunc}]"

# local shadows a global with an unset value; global restored after
h() {
  local g
  echo "shadowed g: [${g-DEFAULT}]"
}
h
echo "g restored: $g"

# local -a a is an unset (empty) array
arr() {
  local -a a
  echo "len ${#a[@]}"
  [[ -v a ]] && echo "a set" || echo "a unset"
  a=(1 2 3)
  echo "a: ${a[*]}"
}
arr

# local y= (empty value) IS set
e() {
  local y=
  [[ -v y ]] && echo "y set" || echo "y unset"
  echo "y=[${y-DEF}]"
}
e
