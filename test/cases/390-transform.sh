# ${var@Q} — quote for reinput
x=hello
echo "${x@Q}"
y="a b c"
echo "${y@Q}"
z="it's here"
echo "${z@Q}"
empty=""
echo "${empty@Q}"
path=/usr/local/bin
echo "${path@Q}"

# ${var@U} / @L / @u — case transforms
name="John Doe"
echo "${name@U}"
echo "${name@L}"
low="hello world"
echo "${low@u}"

# ${var@E} — ANSI-C escape expansion
esc='a\tb-c'
echo "${esc@E}"

# transforms over array elements
arr=(foo "bar baz" qux)
echo "up: ${arr[@]@U}"
for e in "${arr[@]@Q}"; do echo "elem: $e"; done

# positional params
set -- one "two three"
echo "pos: ${@@U}"
