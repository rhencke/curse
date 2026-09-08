# default / alternate / assign
unset u
echo "default: ${u:-fallback}"
echo "still unset: ${u-dash}"
set_val=value
echo "alt: ${set_val:+present}"
echo "unset alt: ${u:+present}"
echo "assign: ${u:=assigned}"
echo "after assign: $u"

# length
s=hello
echo "len: ${#s}"
echo "poslen: ${#s}"

# prefix / suffix removal
path=/usr/local/bin/curse
echo "base: ${path##*/}"
echo "dir: ${path%/*}"
file=archive.tar.gz
echo "noext: ${file%.*}"
echo "noallext: ${file%%.*}"
echo "stripusr: ${path#/usr/}"

# replacement
csv=a,b,c,d
echo "first: ${csv/,/;}"
echo "all: ${csv//,/;}"
name=hello_world
echo "anchored: ${name/#hello/HI}"
echo "anchend: ${name/%world/WORLD}"

# substring
alpha=abcdefgh
echo "sub: ${alpha:2:3}"
echo "subrest: ${alpha:5}"
echo "subneg: ${alpha: -2}"

# empty removal produces fewer fields
list="  x   y  z "
set_default=${undefined_var:-a b c}
printf '<%s>' $set_default
printf '\n'
