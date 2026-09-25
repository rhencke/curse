# set -v echoes each line as the reader takes it; set -o history records them — the
# lines still run compiled, one logical line at a time
exec 2>&1
echo start
set -v
x=1
for i in 1 2; do
  echo "$i $x"
done
g() { echo "g$1"; }
g 2
set +v
set -o history
echo recorded
y=$((x + 41)); echo $y
history | sed 's/^ *[0-9]* *//' | tail -3
echo end
