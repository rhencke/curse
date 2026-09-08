# POSIX character classes in glob patterns (patsub, case, [[ ]])
s=xx_9y_ZZ
echo "${s//[[:alpha:]]/.}"
echo "${s//[[:digit:]]/#}"
echo "${s//[^[:alnum:]]/-}"
echo "${s//[[:upper:]]/u}"
echo "${s//[[:lower:]]/l}"

# char class in case
case "abc123" in
  [[:alpha:]]*) echo "starts-alpha" ;;
  *) echo "other" ;;
esac
case "9lives" in
  [[:digit:]]*) echo "starts-digit" ;;
esac

# char class in [[ == ]]
[[ "Q" == [[:upper:]] ]] && echo "upper-Q"
[[ "q" == [[:upper:]] ]] || echo "not-upper-q"
[[ "x5" == [[:alpha:]][[:digit:]] ]] && echo "alpha-digit"

# extglob patterns are always available in [[ ]], no shopt needed
[[ --verbose == --@(help|verbose) ]] && echo "at-match"
[[ --oops == --@(help|verbose) ]] || echo "at-nomatch"
[[ foofoo == +(foo) ]] && echo "plus-match"
[[ abc == !(xyz) ]] && echo "neg-match"
[[ color == colo?(u)r ]] && echo "q-match"
[[ colour == colo?(u)r ]] && echo "q-match2"
v=abc
[[ abcabc == +($v) ]] && echo "var-plus"

# case extglob needs the option
shopt -s extglob
case "verbose" in
  @(help|verbose)) echo "case-at" ;;
esac
