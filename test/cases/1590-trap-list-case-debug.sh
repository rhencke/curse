# `trap -l` lists signal names (like `kill -l`), and the DEBUG trap fires before
# a `case` command and before the matched clause's body.
trap -l | grep -c INT          # INT is present
echo "has-term=$(trap -l | grep -c TERM)"

debuglog() { echo "  [$1]"; }
trap 'debuglog $LINENO' DEBUG
name=foo.py
case $name in
  *.py) echo python ;;
  *.sh) echo shell ;;
esac
echo ok
