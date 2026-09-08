# the `time` keyword runs the pipeline; timing goes to stderr (not compared)
time echo hello
echo "rc after echo: $?"

time false
echo "rc after false: $?"

# time with -p
time -p echo pflag
echo "rc after -p: $?"

# time over a pipeline
time echo a b c | wc -w | tr -d ' '
echo "rc after pipe: $?"

# time a compound command
time for i in 1 2 3; do echo "n=$i"; done

# time and the ! inversion together
time ! false
echo "rc after time !: $?"
