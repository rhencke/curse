# <> opens a file for read/write (default fd 0 = read side)
d=$(mktemp -d); cd "$d"
printf 'line one\nline two\n' > data

# read from a file via <>
read first <> data
echo "read: [$first]"

# <> creates the file if it does not exist
read x <> newfile
echo "created rc=$? x=[$x]"
[ -f newfile ] && echo "newfile exists"

# write via 1<> without truncating (overwrites from the start)
printf 'ABCDEFGH' > buf
printf 'xyz' 1<> buf
echo "overwrite: [$(cat buf)]"

# a whole loop reading via <>
while read ln; do echo "got: $ln"; done <> data

cd /; rm -rf "$d"
