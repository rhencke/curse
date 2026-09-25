# set -x reaches compiled runtime fragments: eval'd code and a sourced file trace one
# level deeper (`++`), a recurring trap handler too; an eval'd line sees the live aliases
exec 2>&1
set -x
for i in 1 2 3; do eval "echo e$i; x=\$((i+1))"; done
trap 'echo t; y=1' ERR
for i in 1 2 3; do false; done
trap - ERR
f=inc.sh
printf 'echo sourced; z=2\n' > "$f"
for i in 1 2; do . "$f"; done
rm -f "$f"
set +x
shopt -s expand_aliases
alias hi='echo hi'
for i in 1 2 3; do eval "hi $i"; done
unalias hi
for i in 1 2; do eval 'hi 2>/dev/null || echo none'; done
