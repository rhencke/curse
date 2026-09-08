# set -o noclobber: > won't overwrite an existing file
d=$(mktemp -d); cd "$d"
echo initial > f
set -o noclobber

echo blocked > f 2>/dev/null
echo "clobber rc=$? content=[$(cat f)]"

# >| forces the overwrite
echo forced >| f
echo "force: [$(cat f)]"

# >> append is still allowed
echo more >> f
echo "lines: $(wc -l < f | tr -d ' ')"

# > to a nonexistent file is fine
echo hi > g
echo "new: [$(cat g)]"

# turning noclobber off restores >
set +o noclobber
echo overwrite > f
echo "after: [$(cat f)]"

# -C flag form
set -C
echo x > g 2>/dev/null
echo "flag rc=$? g=[$(cat g)]"
set +C

cd /; rm -rf "$d"
