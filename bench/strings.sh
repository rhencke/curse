# string building, case conversion, substitution
acc=""
for ((i=0; i<100000; i++)); do
  s="item_$i"
  u=${s^^}
  r=${u/ITEM_/X}
  acc=$r
done
echo "$acc"
