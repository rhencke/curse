# trap normalizes signal specs: numbers and SIG-prefixes map to canonical names
# (0=EXIT, 2=SIGINT, 15=SIGTERM), and a bare `trap`/`trap -p` lists handlers in
# signal-number order regardless of registration order.

# Register out of order, by number, name, and SIG-name.
trap 'echo term' TERM
trap 'echo int' 2
trap 'echo sigquit' SIGQUIT
trap -p

echo ---

# 0 is EXIT; registering the same handler for several signals at once works.
trap 'echo multi' 15 EXIT INT
trap

echo ---

# An out-of-range number is an invalid signal spec.
trap 'echo x' 99 2>/dev/null; echo "bad=$?"

# Resetting by number clears the same slot as the name.
trap - 2
trap -p | grep -c SIGINT
