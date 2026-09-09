# `read` line/field/escape semantics, and the stdin read-position shared across
# subshell and command-substitution boundaries (bash uses one underlying fd).

# No name -> $REPLY gets the whole line, with no IFS splitting or stripping.
echo '  a b  ' | (read; echo "[$REPLY]")
# One name -> leading/trailing IFS whitespace stripped, no interior splitting.
echo '  a b  ' | (read myvar; echo "[$myvar]")

# A backslash-newline is a line continuation (non-raw); -r keeps it literal and
# stops at the first newline.
printf '  a b  \\\n  line2\n' | (read; echo "[$REPLY]")
printf '  a b  \\\n  line2\n' | (read -r myvar; echo "[$myvar]")

# Non-raw read drops a backslash and keeps the escaped char; -r keeps both.
printf 'one\\ two\n' | (read e; echo "[$e]")
printf 'one\\ two\n' | (read -r r; echo "[$r]")
printf 'a\\tb\n' | (read e; echo "[$e]")
printf 'a\\tb\n' | (read -r r; echo "[$r]")

# Extra vars are cleared; too few leaves the rest empty; a custom IFS splits.
c=preset; printf 'a b\n' | { read a b c; echo "'$a' '$b' '$c'"; }
printf 'a b\n' | { read x y z; echo "'$x' '$y' '$z'"; }
printf 'a:b:c\n' | { IFS=: read x y z; echo "'$x' '$y' '$z'"; }

# No trailing newline: the value is still assigned but status is 1.
printf 'ZZZ' | { read w; echo "status=$? [$w]"; }

# A read inside ( ) or $( ) advances the shared position: the outer read
# continues from the next line.
printf 'l1\nl2\nl3\n' | { (read a; echo "sub:$a"); read b; echo "outer:$b"; }
printf 'm1\nm2\n' | { s=$(read c; echo "$c"); echo "csub:$s"; read d; echo "after:$d"; }

# read -t 0 polls availability without consuming; a positive timeout on an
# exhausted/empty stream reports EOF.
read -t 0 < /dev/null; echo "poll_null=$?"
echo foo | { read -t 0; echo "poll_reply=[$REPLY] $?"; }
read -t 0.5 < /dev/null; echo "timed=$?"
