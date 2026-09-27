# Wherever bash's grammar allows a newline_list between tokens, the lexer has already
# dropped comments and `\<newline>`s and gathers pending here-document bodies at the
# newline (parse.y read_token): after `&&`/`||`/`|`, before `in` (case, for), before a
# function body, inside [[ ]] and NAME=( … ), after a case command — one skipper for all.
\
echo "L$LINENO"
cat <<E1 &&
body1
E1
echo after1 $LINENO
cat <<E2 ||
body2
E2
echo no
echo $LINENO
case a in a) echo x \
; echo y;; esac
case a in a) echo p
esac
[[ -n x &&
  -n y ]] && echo cond $LINENO
for q # c

# more
in 1 2; do echo $q; done
a=(1 # c
2 \
3); echo ${a[@]} $LINENO
f()
# c
{ echo f $LINENO; }; f
case x
# c
in x) echo y $LINENO;; esac
echo a |
# c

cat
if true; then echo t; fi \
; echo semi
echo $LINENO
f2() { echo "$(echo a
# x
echo b)"; }; f2; declare -f f2
