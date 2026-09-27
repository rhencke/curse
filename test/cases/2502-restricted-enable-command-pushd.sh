# A restricted shell refuses `enable -f`/`enable -d` (even with no names, before listing)
# and re-enabling a disabled builtin (enable.def); `command -p` with a NAME, -v/-V
# included, but not bare `command -p` (command.def); pushd/popd's cd errors name them.
set -r
enable -f /nonexist.so foo; echo "f=$?"
enable -d foo; echo "d=$?"
enable -f x; echo "f0=$?"
enable -d; echo "d0=$?"
enable -n echo; enable echo test; echo "re=$?"; enable -n
command -p; echo "p0=$?"
command -pv; echo "pv0=$?"
command -p ls /; echo "p=$?"
command -pv ls; echo "pv=$?"
command -pV ls; echo "pV=$?"
command -v -p ls; echo "vp=$?"
pushd /; echo "pu=$?"
popd; echo "po=$?"
eval 'command -pv ls'; echo "ev=$?"
n=0
for ((i = 0; i < 150; i++)); do
	e=$( { command -pv ls; enable -d x; pushd /; } 2>&1 ); n=$((n + $?))
done
echo "loop n=$n"; echo "$e" | sed 's/^[^:]*: line [0-9]*: //'
