# getopts: OPTIND default, invalid name, OPTARG lifecycle
echo "optind-default=$OPTIND"

# parse a normal flag set; OPTIND advances, shift skips consumed args
set -- -a -b val pos1 pos2
while getopts "ab:" opt; do
  echo "opt=$opt optarg=[$OPTARG]"
done
echo "optind=$OPTIND"
shift $((OPTIND - 1))
echo "rest=$*"

# an invalid destination identifier: option still parsed, status 1
set -- -c foo -h
getopts 'hc:' 'bad-name'
echo "invalid-rc=$? OPTARG=$OPTARG OPTIND=$OPTIND"

# OPTARG is left unset after a flag that takes no argument
OPTIND=1
set -- -a
getopts "ab" flag
echo "flag=$flag optarg-set=${OPTARG+yes}"

# silent mode (leading :) reports missing arg / bad option in the name var
OPTIND=1
set -- -b
getopts ":ab:" o
echo "silent=$o OPTARG=$OPTARG"
