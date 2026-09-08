shopt -s extglob

# @(...) exactly one alternative, in a case
for f in cat dog bird cot; do
  case $f in
    @(cat|dog)) echo "$f: pet" ;;
    *) echo "$f: other" ;;
  esac
done

# +(...) one or more; *(...) zero or more; ?(...) zero or one — in [[ ]]
[[ 12345 == +([0-9]) ]] && echo "all digits"
[[ 12a45 == +([0-9]) ]] || echo "not all digits"
[[ "" == *(x) ]] && echo "empty ok"
[[ xxx == *(x) ]] && echo "xxx ok"
[[ color == colo?(u)r ]] && echo "color ok"
[[ colour == colo?(u)r ]] && echo "colour ok"
[[ colouur == colo?(u)r ]] || echo "colouur no"

# !(...) negation
[[ hello == !(world) ]] && echo "not world"
[[ world == !(world) ]] || echo "is world"

# extglob in parameter trimming
file="image.tar.gz"
echo "strip: ${file%.@(gz|bz2|xz)}"
echo "longest: ${file%%.@(tar|gz)*}"

# extglob in pathname expansion
d=$(mktemp -d); cd "$d"
touch a.jpg b.png c.gif d.txt
echo images: @(*.jpg|*.png)
echo not-txt: !(*.txt)
cd /; rm -rf "$d"

# nested extglob
[[ foobarbar == foo+(bar) ]] && echo "nested +()"
[[ axbxc == @(a|x)*(x|b)c ]] && echo "combo"
