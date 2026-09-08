# $- reflects the current single-letter option flags
echo "base: [$-]"
set -e
echo "errexit: [$-]"
set -u
echo "nounset: [$-]"
set +eu
echo "reset: [$-]"

# usable in a case / test
set -e
case $- in
  *e*) echo "e is set" ;;
  *) echo "no e" ;;
esac
set +e
[[ $- == *e* ]] && echo "still e?" || echo "e cleared"

# ${-} brace form and length
echo "brace: [${-}]"
echo "len: ${#-}"
