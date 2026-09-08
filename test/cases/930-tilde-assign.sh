# tilde expansion after = and : in assignment words
HOME=/home/u

# scalar assignment: leading and colon-separated tildes
p=~/bin:~/lib:/usr/bin
echo "p=$p"

# assignment-form command arguments expand tildes too
echo a=~/x
echo PATH=~/a:~/b

# array literal element values ([k]=v and bare)
a=([1]=~/one [2]=~/two ~/three)
echo "a1=${a[1]} a2=${a[2]} a3=${a[3]}"

# associative array values
declare -A m=([home]=~ [sub]=~/deep)
echo "home=${m[home]} sub=${m[sub]}"

# a non-assignment word only expands a leading tilde (colon does not)
echo ~/x:~/y

# quoting suppresses tilde expansion
q="~/nope"
echo "q=$q"
r='~/also'
echo "r=$r"

# += append with a tilde value
s=start:
s+=~/end
echo "s=$s"

# ~user (unsupported form) stays literal when the user is unknown-looking
echo "lit=a~b"
