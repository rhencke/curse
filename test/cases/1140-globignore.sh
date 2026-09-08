# GLOBIGNORE removes matches that also match one of its colon-separated patterns
d=$(mktemp -d); cd "$d"

touch one.md one.txt
mkdir -p foo
touch foo/two.md foo/two.txt

# *.txt matches one.txt (single component) but not foo/two.txt (* can't cross /)
GLOBIGNORE=*.txt
echo *.* foo/*.*
unset GLOBIGNORE
rm -rf foo one.md one.txt

# multiple patterns
touch hello.c hello.h hello.o hello
GLOBIGNORE=*.o:*.h
echo hello*
unset GLOBIGNORE
rm -f hello hello.c hello.h hello.o

# POSIX character classes survive the colon-split (the : inside [[:alnum:]])
touch _lib.py app.toml 42.log
GLOBIGNORE='[[:alnum:]]*'
echo *
GLOBIGNORE='[[:digit:]]*'
echo *
unset GLOBIGNORE
rm -f _lib.py app.toml 42.log

# an all-matching GLOBIGNORE leaves the pattern unexpanded (like nullglob off)
touch a.txt b.txt
GLOBIGNORE=*
echo *
unset GLOBIGNORE
rm -f a.txt b.txt

# setting GLOBIGNORE enables dotglob (leading-dot names become candidates)
touch .hidden visible
GLOBIGNORE=nope
echo *
unset GLOBIGNORE
echo *
rm -f .hidden visible

# with GLOBIGNORE + nullglob, an empty result drops the word entirely
touch keep.txt
GLOBIGNORE=*.txt
shopt -s nullglob
echo start *.txt end
shopt -u nullglob
unset GLOBIGNORE

cd /; rm -rf "$d"
