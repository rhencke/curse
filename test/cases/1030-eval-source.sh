# eval option handling and source PATH search
d=$(mktemp -d); cd "$d"

# eval ignores a leading --, and rejects invalid options
eval -- echo "hi from eval"
eval "x=7; echo x=$x"
eval -z 2>/dev/null; echo "badopt=$?"
eval - 2>/dev/null; echo "dash=$?"
eval 2>/dev/null; echo "empty=$?"

# source/. searches PATH (regular files only), PATH before cwd
mkdir -p libdir
echo 'echo from-path; SRCVAR=viapath' > libdir/mylib
echo 'echo from-cwd; SRCVAR=viacwd' > mylib
PATH="libdir:$PATH"
. mylib
echo "srcvar=$SRCVAR"

# source accepts --
echo 'echo dashdash-ok' > script.sh
source -- script.sh

# source passes positional parameters
echo 'echo "args:$1:$2"' > withargs.sh
. withargs.sh one two

# a directory in PATH is skipped
mkdir -p libdir/dircmd
echo 'echo real-file' > realcmd
. dircmd 2>/dev/null; echo "dir-skipped=$?"

cd /; rm -rf "$d"
