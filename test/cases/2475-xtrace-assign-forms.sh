# set -x of assignments as bash traces them:
# - a command prefix is traced once BOUND, with its bound value: `n+=3 cmd` on a declare -i
#   n traces `n=6` (make_variable_value appended), `s+=b cmd` `s=ab`, an array's [0] + x,
#   a -l var folded; a `PS4=… cmd` binding (and later ones) under the NEW PS4, the command
#   itself under the PS4 outside its temporary environment
# - a standalone readonly assignment expands and traces before its error (interp too)
# - a multi-line NAME=( … ) traces as bash's parser rebuilt it, `m=(1 2 3)`, at its last line
# - $LINENO in PS4 is the traced command's line (a prefixed command, a for header, an
#   inlined function call)
exec 2>&1
declare -i n=3
s=a; a=(1); declare -l l=Q
readonly r=1
set -x
n+=3 true
n+=3
s+=b true
a+=x printenv a
l+=Z printenv l
PS4='>> ' true
PS4='>> ' /bin/true
x=1 PS4='>> ' y=2 true
r=$(echo v)
echo after
m=(1
  2 # two
  3)
m=(  x   "a  b"  )
PS4='+[$LINENO] '
y=2 true
f() {
	y=5 true
}
f
for i in 1; do
	y=6 :
done
set +x
PS4='+ '
g() { set -x; z+=1 true; PS4='] ' w=$1 :; set +x; }
for ((k = 0; k < 160; k++)); do g "$k"; done 2>&1 | sed 's/[0-9][0-9]*$/N/' | sort | uniq -c
for ((k = 0; k < 160; k++)); do g "$k"; done 2>trace.txt
sed 's/[0-9][0-9]*$/N/' trace.txt | sort | uniq -c
rm -f trace.txt
echo end
