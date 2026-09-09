# shopt / shopt -o validate option names, and getting the exit status right:
# listing all options is status 0, a specific query reflects on/off, and an
# unknown name is an error (nothing printed for it).

# Listing everything is status 0 even though most options are off.
shopt -p >/dev/null; echo "list_all=$?"
shopt -p -o >/dev/null; echo "list_all_o=$?"

# A specific query: off -> 1, on -> 0.
shopt -p extglob >/dev/null; echo "off=$?"
shopt -s extglob
shopt -p extglob >/dev/null; echo "on=$?"

# An unknown option name errors with status 1 and prints nothing to stdout.
shopt -p bogus_opt 2>/dev/null; echo "bad=$?"
shopt -s bogus_opt 2>/dev/null; echo "bad_set=$?"
shopt -p -o bogus_setopt 2>/dev/null; echo "bad_o=$?"

# A known set -o option prints and reflects state.
shopt -p -o errexit
set -e
shopt -p -o errexit
