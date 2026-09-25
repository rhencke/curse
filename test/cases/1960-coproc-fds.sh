# coproc pipe ends, from bash's execute_cmd.c (execute_coproc) and coproc_setvars:
# the shell's ends (63 60) are close-on-exec — no child inherits them — and a
# script that ends with its coproc still running doesn't wait for it (the
# coproc sees EOF on its stdin once the shell is gone).
coproc cat
ls /proc/self/fd | tr '\n' ' '; echo
echo "fds: ${COPROC[*]}"
echo hi >&"${COPROC[1]}"
read -r -u "${COPROC[0]}" l; echo "got $l"
( ls /proc/self/fd | tr '\n' ' '; echo )
echo "end"
