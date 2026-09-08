# command -v / -V and builtin option handling
myfunc() { echo x; }

# -v prints the name/path for found things, nothing for missing (silent)
command -v echo
command -v myfunc
command -v ls | grep -q / && echo "v-file-path"
command -v while
command -v no_such_zz; echo "v-missing=$?"

# -V is the verbose form; reports a failure to stderr with status 1
command -V echo
command -V while
command -V ls | grep -q "ls is /" && echo "V-file"
command -V no_such_zz 2>err.txt; echo "V-missing-rc=$?"
grep -o "no_such_zz: not found" err.txt; rm -f err.txt

# command runs its argument bypassing a same-named function
false() { echo "shadow"; }
command false; echo "bypass-rc=$?"

# builtin runs a builtin, honoring a leading --
builtin -- true; echo "builtin-true=$?"
builtin printf '%s\n' viabuiltin
