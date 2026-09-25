# coproc compiles: the command runs as a compiled background fragment wired to NAME's
# pipes; NAME/NAME_PID are set, and the coprocess is reaped (NAME unset) once it ends
coproc UP { while read -r l; do echo "${l^^}"; done; }
for w in one two three; do echo "$w" >&"${UP[1]}"; read -r got <&"${UP[0]}"; echo "got $got"; done
[[ -n $UP_PID ]] && echo "pid set"
exec {UP[1]}>&-
wait "$UP_PID" 2>/dev/null; echo waited  # (its status races: bash may already have reaped the coproc)
coproc sq { for i in 1 2 3; do echo $((i*i)); done; }
exec {fd}<&"${sq[0]}"
while read -r v <&$fd; do echo "sq $v"; done
wait 2>/dev/null
echo "sq gone: ${sq[@]:-unset}"
