items="a b c"
printf '<%s>' $items
printf '\n'
printf '<%s>' "$items"
printf '\n'
prefix=x
printf '<%s>' $prefix$items
printf '\n'
spaced="   lots   of   space   "
printf '<%s>' $spaced
printf '\n'
