# getopts leaves OPTIND where it stopped after a non-empty scan, but rewinds it
# to 1 when called with no arguments at all.

parse() {
  local o
  OPTIND=1
  while getopts "ab:" o; do echo "opt=$o OPTARG=${OPTARG:-}"; done
  echo "OPTIND=$OPTIND"
}

parse -a -b val          # all options consumed; OPTIND points past them
echo ---
parse -a x -b val        # stops at the non-option x
echo ---
# No arguments at all: OPTIND rewinds to 1.
set --
OPTIND=9
getopts "ab:" o
echo "empty st=$? OPTIND=$OPTIND"
