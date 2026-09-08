# pushd / popd / dirs directory stack (temp path normalized to D)
d=$(mktemp -d)
mkdir -p "$d/a" "$d/b" "$d/c"
cd "$d"
HOME=/nonexistent_home_zz   # keep tilde substitution out of the way
norm() { sed "s|$d|D|g"; }

pushd "$d/a" >/dev/null
echo "1=$(dirs | norm) rc=$?"
pushd "$d/b" >/dev/null
echo "2=$(dirs | norm)"

echo "--p--"; dirs -p | norm
echo "--v--"; dirs -v | norm

# cd replaces the current (top) entry without disturbing the rest
cd "$d/c"
echo "3=$(dirs | norm)"

popd >/dev/null
echo "4=$(dirs | norm)"
popd >/dev/null
echo "5=$(dirs | norm)"

# popping the last entry is an error
popd 2>/dev/null; echo "empty=$?"

# usage errors
pushd -z 2>/dev/null; echo "badflag=$?"
pushd "$d/a" "$d/b" 2>/dev/null; echo "toomany=$?"
dirs zzz 2>/dev/null; echo "dirsarg=$?"
popd zzz 2>/dev/null; echo "popdarg=$?"

# dirs -c clears back to just the current dir
cd "$d"
pushd "$d/a" >/dev/null
dirs -c
echo "cleared=$(dirs | norm)"

cd /; rm -rf "$d"
