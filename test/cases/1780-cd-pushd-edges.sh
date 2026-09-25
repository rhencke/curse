# cd/pwd (builtins/cd.def) and pushd/popd/dirs (builtins/pushd.def) edge cases:
# CDPATH (relative/empty/'.'/tilde entries, what gets printed, -P, privileged
# mode), cd "" / empty HOME / empty OLDPWD, `cd -` printing OLDPWD verbatim,
# logical-vs-literal fallback through symlinks, posix-mode cd, -@ rejected,
# readonly/unset PWD and OLDPWD, cdable_vars, pwd vs a stale $PWD, a deleted
# cwd, dirs ~ abbreviation with HOME=/, DIRSTACK assignment/unset/local,
# rotation, -n, and every pushd/popd/dirs diagnostic.
base=$PWD
r() { echo "${PWD#$base}|${OLDPWD#$base}"; }
n() { sed "s/^.*line [0-9]*: //; s|$base|B|g"; }
mkdir -p a/b a/x c d/e; ln -s a/b lnk; touch f

echo "== errors"
( cd -@ a; echo st=$?; ) 2>&1 | n
{ cd -x; echo st=$?; cd nosuch; echo st=$?; cd f; echo st=$?
  cd f/..; echo st=$?; cd nosuch/..; echo st=$?; cd a c; echo st=$?; cd -- -x; echo st=$?
  pwd -x; echo st=$?; } 2>&1 | n

echo "== empty operand / HOME / OLDPWD"
cd a; cd ""; echo st=$?; r; cd "$base"
cd a; HOME=; cd; echo st=$?; r; HOME=$base; cd "$base"
OLDPWD=; cd -; echo st=$?; r
unset OLDPWD; { cd -; echo st=$?; } 2>&1 | n
( unset HOME; cd; echo st=$? ) 2>&1 | n
OLDPWD=a/../c; cd - | n; cd -; r; cd "$base"
cd -e a; echo st=$?; cd -LP "$base/lnk"; r; cd -PL "$base/lnk"; r; cd "$base"

echo "== logical first, literal fallback"
cd lnk/../c; echo st=$?; r; pwd -P | n; cd "$base"
cd lnk/../x 2>/dev/null; echo st=$?; r; pwd -P | n; cd "$base"
( set -o posix; cd lnk/../x; echo st=$?; r ) 2>&1 | n
cd //; echo "$PWD"; cd ///; echo "$PWD"; cd "$base"; cd a//b/./; r; cd "$base"

echo "== CDPATH"
CDPATH=:$base/d; cd e | n; cd e >/dev/null; r; cd "$base"
CDPATH=$base/d:; cd a | n; cd a; echo st=$?; r; cd "$base"
CDPATH=d; cd e | n; cd -P e | n; cd e >/dev/null; r; cd "$base"
CDPATH=.; cd a | n; cd -P a | n; cd "$base"
CDPATH=:; cd a | n; cd a; r; cd "$base"
CDPATH='~/d'; cd e | n; cd "$base"
CDPATH=$base; cd -P lnk | n; cd lnk | n; cd "$base"
CDPATH=$base/a; { cd ./b; echo st=$?; cd zz; echo st=$?; } 2>&1 | n
( set -p; CDPATH=$base/a; cd x; echo st=$? ) 2>&1 | n
unset CDPATH; cd "$base"

echo "== cdable_vars"
shopt -s cdable_vars; v=a/x; w=$base/c
cd v | n; ( cd v; r ); cd w | n; ( CDPATH=$base/c; cd v; echo st=$?; r ) | n
{ cd nosuchvar; echo st=$?; } 2>&1 | n; shopt -u cdable_vars

echo "== PWD / OLDPWD variables"
( readonly OLDPWD; cd a; echo st=$?; r ) 2>&1 | n
( readonly PWD; cd a; echo st=$?; r; pwd ) 2>&1 | n
( unset PWD; cd a; echo st=$?; echo "${OLDPWD-unset}"; declare -p OLDPWD ) 2>&1 | n
cd lnk; PWD=/junk; pwd | n; pwd -L | n; pwd -P | n; cd .; r; cd "$base"
cd lnk; ( set -o posix; pwd -P >/dev/null; r ); cd "$base"

echo "== deleted cwd"
mkdir gone; cd gone; rmdir ../gone; cd ..; echo st=$?; r
mkdir gone; cd gone; rmdir ../gone; pwd -P >/dev/null 2>&1; echo st=$?; cd "$base" 2>/dev/null
mkdir gone; cd gone; rmdir ../gone; cd . 2>/dev/null; echo st=$?; r; cd "$base"

echo "== pushd / popd / dirs"
mkdir -p p q s t
pushd p; pushd ../q; pushd ../s; pushd ../t; dirs -v; dirs -p; dirs -l | n
{ dirs -lv; echo st=$?; } 2>&1 | n
pushd +1; pushd -1; pushd +0; pushd -0; pushd -n +2; echo "${PWD#$base}"
dirs +1; dirs -1; dirs +0; dirs -0; dirs -v +2; dirs -v -2; dirs +4; dirs -4
{ dirs +5; echo st=$?; dirs -x; echo st=$?; dirs zz; echo st=$?
  pushd -5; echo st=$?; pushd +x; echo st=$?; pushd -P p; echo st=$?; pushd nosuch; echo st=$?
  popd +5; echo st=$?; popd -q; echo st=$?; popd zz; echo st=$?; } 2>&1 | n
pushd -n "sp ace"; echo "${DIRSTACK[1]}|${#DIRSTACK[@]}"
popd +1; popd -0; popd -n; echo "${PWD#$base}"; dirs -c +1; dirs
{ popd; echo st=$?; popd +1; echo st=$?; pushd; echo st=$?; pushd +1; echo st=$?
  pushd -n; echo st=$?; dirs +1; echo st=$?; } 2>&1 | n
cd "$base"; pushd p >/dev/null; pushd ../q >/dev/null; rmdir ../p
{ popd; echo st=$?; pushd; echo st=$?; pushd +1; echo st=$?; } 2>&1 | n; dirs; mkdir ../p
echo ~0 ~1 ~2 ~-1 ~3 | n

echo "== DIRSTACK writes"
DIRSTACK[1]=$base/c; DIRSTACK[0]=zz; DIRSTACK[7]=zz; dirs; echo "${#DIRSTACK[@]}"
DIRSTACK=(x y z); dirs; echo "${#DIRSTACK[@]}"
fn() { local DIRSTACK=(); echo "local=${#DIRSTACK[@]}"; }; fn; dirs
unset 'DIRSTACK[1]'; dirs; unset DIRSTACK; dirs; echo "[${DIRSTACK[*]}]"
declare -p DIRSTACK 2>&1 | n
cd "$base"; dirs -c
HOME=/; cd /; dirs; HOME=$base/; cd "$base/p"; dirs | n
