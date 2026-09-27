# Pinned bash behaviour: an out-of-range SECONDS assignment is 0 (strtoimax overflow), a
# command list ending in `;` followed by lines holding only a backslash-newline keeps $?,
# `compopt +o` with no option name is "option requires an argument" (status 2) and
# `local -f -Z` is an invalid option (status 2) — once, then in a hot loop. (Only the
# first SECONDS assignment: once read, bash's SECONDS is integer-attributed and a later
# overflowing assignment is evaluated arithmetically, wrapping.)
SECONDS=99999999999999999999999; echo $SECONDS
false;
\
\
echo $?
compopt +o; echo "compopt: $?"
f() { local -f -Z; echo "local: $?"; }; f
g() {
	false;
\
\
	r=$?
	compopt +o 2>/dev/null; c=$?
	local -f -Z 2>/dev/null; l=$?
	echo "$r $c $l"
}
for ((i = 0; i < 200; i++)); do g; done | sort | uniq -c
