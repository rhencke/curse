# shell_execve on ENOEXEC: check_binary_file (general.c) calls a file with an ELF magic
# binary even when it is too short / corrupt for the kernel ("cannot execute binary
# file: Exec format error", 126), else a NUL in its first line (first two after `#!`);
# and a no-shebang script runs with the pathname it was run by as $0 — the full path
# when found along PATH.
T=$(mktemp -d) || exit 1; cd "$T" || exit 1
printf '\177ELF' > e4; printf '\177ELF\nxx\n' > e5; printf 'text\0nul\n' > nul1
printf 'echo line1\n\0\n' > nul2; printf 'echo "0=$0 [$*]"\n' > noshe
chmod +x e4 e5 nul1 nul2 noshe
PATH=$T:$PATH
run() { for f in e4 e5 nul1 nul2 noshe ./noshe; do "$f" a b; echo "$f st=$?"; done 2>&1 | sed "s#$T#T#g"; }
run
x=$(noshe q); echo "${x/$T/T}"
(noshe r) | sed "s#$T#T#"
for ((i = 0; i < 150; i++)); do r=$(run); done; echo "$r"
cd / && rm -rf "$T"
