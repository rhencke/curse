# case statements (and their bare-pattern `)`) inside command substitutions

echo $(case x in x) echo ok;; esac)
echo $(case dog in cat|dog) echo pet;; *) echo no;; esac)
echo $(case y in (y) echo lead;; esac)

# nested case inside a command sub
r=$(case a in a) case b in b) echo nested;; esac;; esac)
echo "nested=$r"

# case assigned through a command sub, with a body that has parens/quotes
val=$(
  case "$1" in
    "") echo empty ;;
    *) echo "got (something)" ;;
  esac
)
echo "val=$val"

# a case whose body runs a pipeline and a subshell
out=$(case hi in h*) (echo A; echo B) | tr 'A-Z' 'a-z' ;; esac)
echo "out=$out"

# multiple command subs on one line, each containing a case
echo $(case 1 in 1) echo one;; esac)-$(case 2 in 2) echo two;; esac)

# case inside process substitution
cat <(case ok in ok) echo via-procsub;; esac)

# for-loop `in` inside a case body must not confuse pattern scanning
echo $(case run in run) for i in a b c; do printf '%s' "$i"; done ;; esac)
