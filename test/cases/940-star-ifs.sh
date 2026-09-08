# $* and ${a[*]} join with IFS[0]; $@ / ${a[@]} join with a space
set -- alpha beta gamma
a=(one two three)

# default IFS (space)
echo "star=$*"
echo "at=$@"

# custom single-char IFS
IFS=,
echo "star=$*"
echo "at=$@"
echo "arr_star=${a[*]}"
echo "arr_at=${a[@]}"

# multi-char IFS uses the first char for joining
IFS=:-
echo "star=$*"
echo "arr_star=${a[*]}"

# empty IFS joins with no separator
IFS=
echo "star=$*"
echo "arr_star=${a[*]}"

# unset IFS falls back to a space
unset IFS
echo "star=$*"
echo "arr_star=${a[*]}"
