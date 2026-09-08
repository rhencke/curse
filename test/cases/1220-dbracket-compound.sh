# [[ ]] compound expressions: tight whitespace, precedence, quoting

# ! and ( need no surrounding space, and ]] needs no space before it
[[ ''||! (1 == 2)&&(2 == 2)]] && echo "1:true"
[[ (2 == 2)]] && echo "2:true"
[[ (1 == 1)&&(2 == 2) ]] && echo "3:true"

# && binds tighter than || inside [[ ]]
[[ True || '' && '' ]] && echo "4:true"

# a quoted operator is a literal string, not an operator
[[ '-z' == foo ]]; echo "5:$?"
[[ '!' == '!' ]] && echo "6:true"
[[ ^ == ^ ]] && echo "7:true"

# unary tests still work
[[ -z "" ]] && echo "8:empty"
[[ -n abc ]] && echo "9:nonempty"
[[ ! -z x ]] && echo "10:not-empty"

# negation and grouping precedence
[[ ! ( 1 == 2 ) ]] && echo "11:true"
