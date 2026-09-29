# Pinned bash behaviour: `declare -f` prints a $( … ) body as parse_comsub parsed it at
# definition time — only its syntax was checked, so an alias the body itself defines (after
# its own `shopt -s expand_aliases`) is NOT expanded in the listing; it expands only when the
# body runs. (F98 sub-item 2568.)
f() {
	x=$(shopt -s expand_aliases; alias f_="echo 2"
f_ y); echo "$x"
	y=$(
	shopt -s expand_aliases
	alias e_='echo 1
echo 2'
	e_ $1
	)
}
declare -f f
f a; echo "$y" | tr '\n' ' '; echo
eval 'g() { z=$(shopt -s expand_aliases; alias q_="echo q"
q_ r); }'
declare -f g
g; echo "$z"
for ((i = 0; i < 150; i++)); do declare -f f; f "$i" >/dev/null; done | sort | uniq -c
