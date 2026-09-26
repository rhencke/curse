# select's menu prints each item as a C string: an item with a NUL (`$'ab\0cd'`) shows
# only `ab` (bash print_select_list); the choice and REPLY are unaffected.
exec 2>&1
select x in $'ab\0cd' "e f" g; do echo "[$x] [$REPLY]"; done <<< $'1\n\n2\n9'
echo st=$?
f() { select y in "$@"; do echo "<$y>"; break; done <<< 2; }
f $'p\0q' $'r\0s'
