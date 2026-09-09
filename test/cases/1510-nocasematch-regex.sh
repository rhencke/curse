# `shopt -s nocasematch` makes the `[[ =~ ]]` regex operator case-insensitive,
# matching what it already did for `==` glob and `case`. Turning it back off
# restores case sensitivity.
shopt -s nocasematch
[[ a =~ A ]]; echo $?
[[ A =~ a ]]; echo $?
[[ hello =~ ^H.*O$ ]]; echo $?
[[ a =~ [A] ]]; echo $?
shopt -u nocasematch
[[ a =~ A ]]; echo $?
[[ HELLO =~ ^h ]]; echo $?
