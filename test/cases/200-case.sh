for fruit in apple banana cherry grape; do
  case "$fruit" in
    apple)
      echo "an apple"
      ;;
    banana|grape)
      echo "yellow or purple: $fruit"
      ;;
    c*)
      echo "starts with c: $fruit"
      ;;
    *)
      echo "unknown: $fruit"
      ;;
  esac
done

x=hello
case $x in
  h??lo) echo "matched h??lo" ;;
  *) echo nomatch ;;
esac

case 42 in
  [0-9]) echo single ;;
  [0-9][0-9]) echo double ;;
  *) echo many ;;
esac

classify() {
  case "$1" in
    "") echo empty ;;
    -*) echo option ;;
    *) echo plain ;;
  esac
}
classify ""
classify -v
classify hello
