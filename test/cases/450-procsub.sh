# process substitution <(cmd): the command's output appears as a file path

# as command arguments
cat <(echo one) <(echo two)

# diff of two identical substitutions -> no diff, exit 0
diff <(printf 'a\nb\n') <(printf 'a\nb\n') && echo "same"

# redirect stdin from a process substitution
while read line; do echo "got: $line"; done < <(printf 'x\ny\nz\n')

# feed a counted stream
wc -l < <(printf 'p\nq\nr\ns\nt\n')

# a pipeline inside the substitution
cat <(printf '3\n1\n2\n' | sort)
