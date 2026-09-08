# globstar: ** matches across directory levels when shopt -s globstar
d=$(mktemp -d)
cd "$d"
mkdir -p a/b/c
touch top.txt a/one.txt a/b/two.txt a/b/c/three.txt a/b/c/deep.log a/.hidden

# without globstar, ** behaves like a single-level *
shopt -u globstar
echo "off:" **/*.txt

# with globstar, ** spans zero or more levels
shopt -s globstar
echo "txt:" **/*.txt
echo "all:" **
echo "sub:" a/**/*.txt
echo "logs:" **/*.log

cd /
rm -rf "$d"
