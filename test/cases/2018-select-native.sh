# select compiled as a native loop (rt.select_menu/select_next): menu + PS3 on stderr,
# REPLY/NAME, empty line redisplays, break/continue (also multi-level), EOF ends (status 1).
PS3="pick> "
set -- a "b c"
select v in "$@" z; do
  echo "v=[$v] REPLY=$REPLY"
  case $REPLY in 3) break;; 2) continue;; esac
  echo tail
done 2>&1 <<'IN'
1

2
3
IN
echo "st=$? v=$v"
for i in 1 2; do
  select w in x y; do echo "inner $i $w"; break 2; done <<< "1"
done 2>/dev/null
echo end
select q in only; do echo "got $q"; done < /dev/null 2>/dev/null
echo "eof st=$?"
