x=global
show() { echo "x=$x"; }
mutate() {
  local x=local_value
  show
}
show
mutate
show
