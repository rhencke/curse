# unset / local semantics: function fallback, local-unset hiding, readonly
# shadowing, and re-declaring a local.

# `unset name` (no -f) removes a variable if one exists, otherwise a function.
greet() { echo fn; }
greet=hi
unset greet              # a variable exists -> the variable goes, function stays
echo "[${greet:-gone}]"
greet
unset greet              # now only the function -> it goes
greet 2>/dev/null; echo "greet_st=$?"

# Unsetting a local does NOT reveal an enclosing variable; it stays unset for the
# rest of the function (even a second unset), and is restored when it returns.
x=global
f() { local x=foo; echo "x=$x"; unset x; echo "x=[$x]"; unset x; echo "x=[$x]"; }
f
echo "after=$x"

# Unsetting a plain global from inside a function does remove it.
y=g
g() { unset y; echo "in=[$y]"; }
g
echo "outer=[$y]"

# A readonly variable cannot be shadowed by a fresh local.
readonly r=1
h() { local r=2; echo "r=$r"; }
h 2>/dev/null; echo "h_st=$?"

# Re-declaring an existing local without a value keeps it; with a value resets.
k() { local v=bar; local v; echo "keep=$v"; local v=baz; echo "reset=$v"; }
k
