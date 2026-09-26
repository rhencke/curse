# mailcheck.c and the non-readline parts of bashline.c/parse.y an interactive shell fed
# from a pipe shows (the shell under test runs as a child via $THIS_SH):
# - prompts: PS1/PS2/PS0 are written to stderr even when it is not a tty, `exit` is
#   echoed at EOF/`exit`; \# counts commands; PROMPT_COMMAND (scalar and array form)
#   runs before each PS1 (not PS2) and keeps $_ and $?; prompt-escape corners (\nnn
#   needs exactly 3 octal digits, >0377 wraps, a NUL is dropped); with line editing on,
#   \n decodes to \r\n and \[ \] to \001 \002
# - mail: MAILCHECK (interactive default 60, integer attribute; 0 = every prompt; <0 or
#   non-numeric = never), MAIL, MAILPATH `file?msg` / `file%msg` with $_ = the file, the
#   "You have mail"/"You have new mail" choice (size grown, atime < mtime), mailwarn,
#   $_ restored after the check
# - interactive defaults: expand_aliases on, HISTSIZE/HISTFILESIZE=500, emacs off with
#   --noediting; `bind` warns "line editing not enabled" when editing is off
# - history in a -i shell: HISTCONTROL/HISTIGNORE, cmdhist joins multi-line commands
# - cd: cdspell corrects typos only when interactive (printing the new dir), CDPATH and
#   cdable_vars echo; ignoreeof / IGNOREEOF counting
S=${THIS_SH:-bash}
# (English diagnostics whatever locale runs this: the filters match bash's C texts)
if [ -n "${LC_ALL-}" ]; then export LANG=$LC_ALL; unset LC_ALL; fi; export LC_MESSAGES=C
export HOME=$PWD HISTFILE= INPUTRC=/dev/null
export T=$PWD
# the job-control chatter carries a pid: drop it; "bash: cd:" prefixes normalized
nojc() { grep -v 'job control\|terminal process group' | sed "s#$T#T#g; s/^[^ :]*: \(cd\|bind\):/X: \1:/"; }
i() { PS1='P$ ' PS2='> ' "$S" --norc --noediting -i "$@" 2>&1 | nojc; }  # prompts shown
q() { PS1= PS2= "$S" --norc --noediting -i "$@" 2>/dev/null | nojc; }    # stdout only

echo "-- prompts go to stderr (not a tty), PS2 for continuations, exit echoed"
printf 'echo a\nif true\nthen echo b\nfi\n' | i
i <<'X'
PS1='[\#]\$ ' PS0='<ps0 \# $((6*7))>'
echo c
x=1; PS1='$x\#${x}> '

shopt -u promptvars
:
exit 3
X
echo "-- PROMPT_COMMAND: array form, \$? and \$_ preserved, not before PS2"
q <<'X'
PROMPT_COMMAND=('echo "pc1 $?"' 'echo pc2; true pcarg')
(exit 4)
PROMPT_COMMAND[5]='echo pc5'; unset 'PROMPT_COMMAND[0]'
echo "[$_]"
for k in 1
do echo "st=$? [$_]"
done
unset PROMPT_COMMAND; echo end
X
echo "-- prompt escapes: \\nnn needs 3 octal digits, wraps past 0377, NUL dropped"
for p in '\7x' '\77x' '\101' '\1011' '\0101' '\555' '\777' '\400a' '\08' '\0a' '\8'; do
	printf '%s=%q\n' "$p" "${p@P}"
done
echo "-- line editing on: \\n is \\r\\n, \\[ \\] are \\001 \\002"
echo 'p="a\nb\[c\]"; printf "%q\n" "${p@P}"' | PS1= "$S" --norc -i 2>/dev/null
echo 'p="a\nb\[c\]"; printf "%q\n" "${p@P}"' | q
echo "-- mail: MAIL, MAILPATH messages with \$_, new vs plain mail, mailwarn"
echo x > mb; echo x > m1; echo x > m2; echo x > m3; echo x > m4; echo x > m6
q <<'X'
MAILCHECK=0 MAIL=mb
echo one; echo more >> mb; touch -a -d @1000 mb; touch -m -d @4000000000 mb; : last
echo "two [$_]"
MAILPATH='m1?got $_ $((1+1)):m2%pct $_'
echo more >> m1; touch -m -d @4000000000 m1 m2
echo three
unset MAILPATH; MAIL=m3
touch -a -d @4000000001 m3; touch -m -d @4000000000 m3
echo four
touch -a -d @1000 m3; touch -m -d @4000000005 m3
echo five
MAILCHECK=-1 MAIL=m4
echo more >> m4; touch -a -d @1000 m4; touch -m -d @4000000000 m4
echo six
MAILCHECK=0
echo seven
shopt -s mailwarn; MAIL=m6
touch -a -d @4000000009 m6
echo eight
X
echo "-- interactive defaults"
echo 'declare -p MAILCHECK; MAILCHECK=2+3; echo "$MAILCHECK $HISTSIZE $HISTFILESIZE"
shopt expand_aliases checkwinsize cdspell dirspell direxpand hostcomplete progcomp no_empty_cmd_completion; set -o | grep -E "^(emacs|vi) "; alias ll="echo aliased"
ll' | env -u MAILCHECK "$S" --norc --noediting -i 2>/dev/null
env MAILCHECK=5 "$S" --norc -i -c 'declare -p MAILCHECK' 2>/dev/null
echo 'echo "$MAILCHECK"' | env -u MAILCHECK "$S" --posix --norc --noediting -i 2>/dev/null
echo "-- bind warns when line editing is off"
echo 'bind -q abort 2>&1 >/dev/null | cat' | q
printf 'set +o emacs; bind -q abort 2>&1 >/dev/null | cat\n' | PS1= "$S" --norc -i 2>/dev/null | nojc
printf 'set -o emacs; bind -q abort 2>&1 >/dev/null | cat; echo ok\n' | q
echo "-- history: HISTCONTROL, HISTIGNORE, cmdhist"
q <<'X'
HISTCONTROL=ignoreboth
echo a
 echo hidden
echo a
echo b
HISTCONTROL=erasedups HISTIGNORE='ls*:&'
echo b
ls >/dev/null
true
true
for i in 1
do :
done
history | sed 's/^ *[0-9]* *//'
X
echo "-- cdspell (interactive only), CDPATH, cdable_vars"
mkdir -p src/lib docs
i <<'X'
PS1= PS2=
shopt -s cdspell
cd sr; pwd; cd "$T"
cd scr; pwd; cd "$T"
cd srcc; pwd; cd "$T"
cd sxc; pwd; cd "$T"
cd src/lbi; pwd; cd "$T"
cd dcos/; pwd; cd "$T"
cd zzz; echo st=$?
shopt -u cdspell; cd sxc; echo st=$?
CDPATH=src; cd lib; cd "$T"; CDPATH=; cd src; cd "$T"
shopt -s cdable_vars; dv=src/lib; cd dv; pwd
X
"$S" -c 'shopt -s cdspell; cd sxc; echo st=$?; pwd' 2>&1 | nojc | sed 's/.*line 1: //'
echo "-- ignoreeof"
printf 'IGNOREEOF=2\necho a\n' | PS1= "$S" --norc --noediting -i 2>&1 | nojc
printf 'set -o ignoreeof\necho $IGNOREEOF\n' | PS1= "$S" --norc --noediting -i 2>&1 | nojc | uniq -c
for v in x 0 -1; do printf 'IGNOREEOF=%s\n' "$v" | PS1= "$S" --norc --noediting -i 2>&1 | nojc | uniq -c; done
