# command substitution scanning: parens inside quotes must not miscount

# a lone close-paren inside a string
echo $(echo ")")
echo "$(echo ")")"
echo $(echo '(')

# parens inside quotes passed to a real command
echo "$(echo 'a(b)c' | tr -d '()')"
echo $(echo "keep (these) parens")

# nested command substitutions, including inside double quotes
echo $(echo $(echo hi))
echo $(echo "$(echo deep)")
echo "outer $(echo "inner $(echo core)")"

# arithmetic inside quotes inside a command sub
echo $(echo "$((3 * 4))")

# ${...} with a brace/paren inside quotes
x=")"
echo ${x:-"("}
y='{}'
echo "${y:+has ) and } chars}"

# a subshell group inside a command sub still balances
echo $( (echo a; echo b) | tr 'a-z' 'A-Z' )

# backticks with a paren in a string
echo `echo ")"`
r=`echo "(x)"`; echo "$r"

# mixed quoting around a command sub (word not delimited by the sub)
foo=FOO
echo $(echo $foo)bar$(echo $foo)
