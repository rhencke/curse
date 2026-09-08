# quoted glob metacharacters match literally in [[ == ]] and case
[[ '*.py' == '*.py' ]] && echo "q1"
[[ foo.py == '*.py' ]] || echo "q2"
[[ foo.py == *.py ]] && echo "q3"
[[ axb == "a*b" ]] || echo "q4"
[[ axb == a*b ]] && echo "q5"

# variable expansion: unquoted is glob-active, quoted is literal
pat='*.txt'
[[ file.txt == $pat ]] && echo "v1"
[[ file.txt == "$pat" ]] || echo "v2"

# escaped metacharacter is literal
[[ 'a?b' == a\?b ]] && echo "esc"
[[ axb == a\?b ]] || echo "esc-noglob"

# bracket class: quoted literal vs active
[[ x == '[x]' ]] || echo "class-lit-noglob"
[[ x == [x] ]] && echo "class-glob"

# case with quoted vs unquoted patterns (first match wins)
check() {
  case $1 in
    '*.py') echo "literal-star" ;;
    *.py)   echo "glob-py" ;;
    *)      echo "other" ;;
  esac
}
check '*.py'
check foo.py
check bar.js

# != honors quoting too
[[ foo.py != '*.py' ]] && echo "ne-literal"
[[ foo.py != *.py ]] || echo "ne-glob"
