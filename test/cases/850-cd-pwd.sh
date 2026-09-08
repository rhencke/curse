# cd: -, --, OLDPWD/PWD export, CDPATH, too-many-args, BAD/.., -P

d=$(mktemp -d)
mkdir -p "$d/a" "$d/b" "$d/search/target"

cd "$d/a"
[ "$(pwd)" = "$d/a" ] && echo "pwd1=ok"

# cd - returns to and prints OLDPWD
cd "$d/b"
cd - >/dev/null
[ "$(pwd)" = "$d/a" ] && echo "back=ok"

# OLDPWD and PWD are exported
cd "$d/a"
cd "$d/b"
env | grep -q "^OLDPWD=$d/a\$" && echo "oldpwd-exported"
env | grep -q "^PWD=$d/b\$" && echo "pwd-exported"

# cd -- treats the next word as the target
cd -- "$d/a"
echo "dd=$(basename "$PWD")"

# too many arguments is an error
cd "$d/a" "$d/b" 2>/dev/null
echo "toomany=$?"

# BAD/.. errors even though it collapses lexically
cd "$d/a"
cd nonexistent_ZZ/.. 2>/dev/null
echo "badparent=$?"

# CDPATH search
CDPATH="$d/search"
cd target >/dev/null
echo "cdpath=$(basename "$PWD")"
unset CDPATH

# -P resolves symlinks, -L (default) keeps the logical path
cd "$d"
ln -s "$d/a" "$d/link"
cd -L "$d/link"
echo "logical=$(basename "$PWD")"
cd "$d"
cd -P "$d/link"
echo "physical=$(basename "$PWD")"

cd /; rm -rf "$d"
