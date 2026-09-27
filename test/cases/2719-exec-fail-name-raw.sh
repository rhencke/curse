# A command that can't be executed is named as it is — shell_execve's file_error /
# internal_error (No such file or directory, cannot execute: required file not found, Is a
# directory, Permission denied) — only `command not found` quotes a name with control
# characters ($'…': printable_filename). curse quoted them all (fuzz F23). And `exec` of a
# file whose interpreter is missing says so, as a command does (no `exec: …: not found`).
D=d2719; rm -rf "$D"; mkdir "$D"
printf '#!/nonexistent/interp\n' > "$D"/$'s\001x'; chmod +x "$D"/$'s\001x'
printf '#!/nonexistent/interp\n' > "$D"/plain; chmod +x "$D"/plain
mkdir "$D"/$'dir\002y'
printf 'echo hi\n' > "$D"/$'np\003z'
$'/x\001y'; echo "st $?"
./$D/$'s\001x'; echo "st $?"
./$D/$'dir\002y'; echo "st $?"
./$D/$'np\003z'; echo "st $?"
$'x\001y'; echo "st $?"
(PATH=; $'x\001y'; echo "empty PATH $?")
(PATH=$D; $'s\001x'; echo "PATH $?")
(PATH=$D; $'np\003z'; echo "PATH $?")
(exec $'/x\001y'); echo "exec $?"
(exec ./$D/plain); echo "exec interp $?"
(exec ./$D/$'np\003z'); echo "exec perm $?"
./$D/$'np\003z' | cat; echo "stage $?"
./$D/$'np\003z' & wait $!; echo "async $?"
x=$(./$D/$'dir\002y'); echo "cmdsub $?"
command ./$D/$'np\003z'; echo "command $?"
f() { ./$D/$'s\001x'; }; f; echo "function $?"
eval "./$D/\$'np\\003z'"; echo "eval $?"
printf '%s\n' "./$D/\$'dir\\002y'" > s2719.sh; . ./s2719.sh; echo "source $?"; rm -f s2719.sh
trap "./$D/\$'np\\003z'; echo \"trap \$?\"" USR1; kill -USR1 $$; trap - USR1
for ((i = 0; i < 150; i++)); do $'/x\001y'; done 2>&1 | sort | uniq -c
rm -rf "$D"
