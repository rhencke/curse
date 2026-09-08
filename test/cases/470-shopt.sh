# shopt: query and toggle glob/match options
shopt -u nullglob dotglob nocasematch
shopt nullglob
shopt dotglob

d=$(mktemp -d)
cd "$d"
touch apple.txt banana.txt .secret cherry.log

# dotglob controls whether * matches dotfiles
shopt -u dotglob
echo nodot: *
shopt -s dotglob
echo dot: *
shopt -u dotglob

# nullglob makes a non-matching pattern vanish
shopt -s nullglob
echo nomatch: *.zzz
shopt -u nullglob
echo literal: *.zzz

# nocasematch makes case / [[ == ]] case-insensitive
val="HELLO"
shopt -s nocasematch
case $val in
  hello) echo "case matched" ;;
  *) echo "case no" ;;
esac
[[ $val == hell? ]] && echo "cond matched"
shopt -u nocasematch
case $val in
  hello) echo "should not" ;;
  *) echo "case off" ;;
esac
[[ $val == hello ]] && echo "should not" || echo "cond off"

cd /
rm -rf "$d"
