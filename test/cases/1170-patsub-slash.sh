# pattern substitution: the pat/repl `/` delimiter respects quotes, and a
# leading unquoted `/` is a literal pattern character (bash's confusing rule).

x='/_/'
# a quoted slash in the pattern is literal, not the delimiter
echo "q1:${x//'/'/c}"
echo "q2:${x//"/"/c}"
# an escaped slash likewise
s=a/b/c
echo "e1:${s//\//-}"
echo "e2:${s/'/'/X}"

# leading-slash "confusing" cases
echo "c3:${x///c}"
echo "c4:${x////c}"
echo "c5:${x/////c}"

# anchored forms keep an empty leading pattern (prepend / append)
y=aXbXc
echo "pre:${y/#/P}"
echo "suf:${y/%/S}"
echo "glob:${y//X/-}"

# a real slash in the data replaced globally
path=/usr/local/bin
echo "path:${path//\//.}"
