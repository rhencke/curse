# trap: signal validation, usage errors, multi-signal, subshell visibility

# same handler for multiple signals; -p prints them with SIG-prefixed names
trap 'echo caught' USR1 USR2
trap -p USR1
trap -p USR2

# reset multiple handlers at once
trap - USR1 USR2
trap -p | grep -c USR1

# invalid signal specification -> status 1
trap 'echo x' NOSUCHSIG 2>/dev/null; echo "invalid=$?"
trap - NOSUCHSIG 2>/dev/null; echo "invalid-reset=$?"

# an action with no signal is a usage error (status 2)
trap 'echo x' 2>/dev/null; echo "missing-sig=$?"

# trap 0 is a synonym for EXIT
trap 'echo done0' 0
trap -p EXIT | grep -q "EXIT" && echo "zero-is-exit"

# trap settings are visible in a subshell via trap -p
trap 'echo bye' EXIT
trap 'echo hup' USR1
count=$(trap -p | grep -c "EXIT\|USR1")
echo "subshell-sees=$count"
