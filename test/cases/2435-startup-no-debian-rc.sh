# Startup files of bash 5.2.21 as released: SYS_BASHRC and SSH_SOURCE_BASHRC are left
# undefined in config-top.h (Debian's bash defines both), so an interactive shell reads
# only ~/.bashrc — never /etc/bash.bashrc — and $SSH_CLIENT/$SSH2_CLIENT don't make a
# `-c` shell read ~/.bashrc (only stdin being a network connection would).
S=${THIS_SH:-bash}
H=$(mktemp -d); cd "$H" || exit
export HOME=$H
echo 'echo rc-read; RCVAR=1' > .bashrc
env -u SHLVL PS1='plain$ ' "$S" -i -c 'echo "PS1=[$PS1] RCVAR=${RCVAR-unset}"' </dev/null 2>/dev/null
env -u SHLVL "$S" --norc -i -c 'echo "norc PS1=[$PS1]"' </dev/null 2>/dev/null
env -u SHLVL SSH_CLIENT='1 2 3' "$S" -c 'echo "ssh1 RCVAR=${RCVAR-unset}"' </dev/null
env -u SHLVL SSH2_CLIENT= "$S" -c 'echo "ssh2 RCVAR=${RCVAR-unset}"' </dev/null
cd / && rm -rf "$H"
