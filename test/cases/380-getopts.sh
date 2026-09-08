# getopts: option parsing with OPTIND / OPTARG, bundling, and rest args
show() {
  local opt out=""
  OPTIND=1
  while getopts "ab:c" opt; do
    case $opt in
      a) out="${out}A" ;;
      b) out="${out}B(${OPTARG})" ;;
      c) out="${out}C" ;;
      '?') out="${out}?" ;;
    esac
  done
  shift $((OPTIND - 1))
  echo "opts=$out rest=[$*]"
}

show -a -b val -c one two
show -ac -b val
show -b
show -x
show one -a
show -- -a
show -abx

# silent mode (leading ':') reports errors via opt/OPTARG, not stderr
silent() {
  local opt out=""
  OPTIND=1
  while getopts ":ab:" opt; do
    case $opt in
      a) out="${out}A" ;;
      b) out="${out}B(${OPTARG})" ;;
      ':') out="${out}miss(${OPTARG})" ;;
      '?') out="${out}bad(${OPTARG})" ;;
    esac
  done
  echo "silent=$out"
}

silent -a -b x
silent -b
silent -z

# explicit argument list instead of the positional params
OPTIND=1
res=""
while getopts "xy:" o -x -y hello; do
  case $o in
    x) res="${res}X" ;;
    y) res="${res}Y(${OPTARG})" ;;
  esac
done
echo "explicit=$res optind=$OPTIND"
