# bash's builtins/history.def, builtins/fc.def, bashhist.c (+ readline histfile.c /
# histexpand.c) in a script with `set -o history`: multi-line entry joining (quoted
# newlines, compound arrays, $(…), lithist, cmdhist off), `history -p` dropping the line,
# HISTSIZE stifling's history_base, history file reading (timestamps, CRLF, blank and
# unterminated lines, multi-line timestamped entries), $HOME/.history when HISTFILE is
# unset, subshells not touching the parent's list, `!` before a search delimiter, fc
# inside a multi-line compound, fc -s substitution corners.
export TZ=UTC
e() { sed 's/^.*line [0-9]*: //'; }
set -o history
history -c

echo "== quoted newlines / compound arrays / comsubs keep their own joins"
echo "m
n" 'o
p'
x=(1
2)
echo $(echo q
echo r)
fc -e : 2 2>&1
history 4 | head -5

echo "== lithist keeps newlines; cmdhist off makes one entry per line"
shopt -s lithist
for i in 1
do echo $i
done
shopt -u lithist cmdhist
for i in 2
do echo $i
done
shopt -s cmdhist
history 9 | head -7

echo "== fc in a multi-line compound sees the compound itself"
{ fc -ln -1
}

echo "== each history -p on a line drops one more entry"
history -c
echo a
history -s b
history -p x; history -p y
history

echo "== HISTSIZE stifling sets history_base to the count removed"
history -c
echo 1; echo 2; echo 3
echo 4
HISTSIZE=2
history
HISTSIZE=1
history
unset HISTSIZE

echo "== reading: #timestamps, CRLF, blank lines, unterminated last line"
history -c
printf '#100\necho one\n#abc\ncrlf\r\n\n\r\nlast' > hf1
history -r hf1
fc -ln 2 | od -c | sed 's/  */ /g'
history -c
HISTTIMEFORMAT='%Y|'
printf '#100\nfor i in 1\ndo :\ndone\n#200\nnext\n' > hf2
history -r hf2
history | sed -n '/1970|/,$p' | sed '/^ *[0-9]* *[0-9]\{4\}|history/,$d'
history -w hf3; sed '/^#1[0-9]\{9\}$/d' hf3
unset HISTTIMEFORMAT

echo "== no HISTFILE: -w/-a use \$HOME/.history"
history -c
unset HISTFILE
echo w1
history -w; echo st=$?
cat .history
HISTFILE=
history -w; echo st=$?
history -a 2>&1 | e; echo st=$?

echo "== subshells and command substitutions keep their own history"
HISTFILE=hf4
history -c
echo s0
( history -s sub1 )
( history -c )
v=$(history -d 1)
v=$(fc -s s0=S0 2>&1); echo "v=[$v]"
history

echo "== ! before a search delimiter is event not found"
set -H
echo a b
echo !e;x 2>&1 | e
echo !; 2>&1 | e
echo st=$?
set +H

echo "== fc -s with an empty pattern"
echo abc
fc -s =X 2>&1 | e
v=$(history -z 2>&1); echo "v=[${v%%$'\n'*}]" | e
