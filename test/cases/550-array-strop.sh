# parameter string ops apply to each element of an array / positional list
files=(foo.txt bar.log baz.txt)

echo "no-ext: ${files[@]%.*}"
echo "no-txt: ${files[@]%.txt}"

paths=(/a/x /b/y /c/z)
echo "base: ${paths[@]##*/}"
echo "dir: ${paths[@]%/*}"

echo "repl: ${files[@]/./_}"
echo "replall: ${files[@]//[aeiou]/-}"

# anchored suffix must be per-element (not the joined string)
words=(ab cb db)
echo "sfx: ${words[@]%b}"

# quoted keeps each result its own field
strip() { for w in "$@"; do echo "w=[$w]"; done; }
strip "${files[@]%.*}"

# positional params
set -- one.a two.b three.c
echo "pos: ${@%.*}"
echo "pos star: ${*#*.}"
