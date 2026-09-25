# alias / unalias, from bash's builtins/alias.def + alias.c (+ parse.y's alias
# handling): listings are sorted and single-quoted per sh_single_quote (an
# embedded ' becomes '\''), a name starting with `-` prints as `alias -- -x=…`,
# posix mode drops the `alias ` prefix unless -p; legal_alias_name rejects
# names with shell metachars, quotes, `$`, `/` or blanks ("invalid alias name",
# status 1); usage errors (status 2); not-found names; unalias -a. Expansion:
# off by default in a script, turned on by `set -o posix` (and off again by
# +o posix); after assignments; not when quoted; a `\<newline>` after the
# name; trailing-blank chaining is decided by the OUTERMOST alias whose text
# ends before the next word (pop_string), and an alias's recursion guard ends
# once its text is consumed; a newline inside an alias value doesn't advance
# LINENO; a function name in command position is alias-expanded.
e() { sed "s/^.*line [0-9]*: //"; }

# --- the builtins ---
alias; echo "empty st=$?"
alias zz=1 aa=2 "mm=it's" Bb=3 _u=4 'bs=a\b' 'dq=$x "y"'
alias -- -x=dash ------=6
alias; echo st=$?
alias -p zz; echo st=$?
alias zz aa nope 2>&1 | e; echo "st=${PIPESTATUS[0]}"
alias -- -x; alias mm
alias a=b=c 'e1=' 1=one '%=pct' 'a.b=dot' 'a:b=c' 'a{b=1' 'a-b=1' '!=bang'; echo st=$?
alias a e1 1 % a.b a:b a{b a-b !
for n in 'a/b' 'a$b' 'a b' "a'b" 'a"b' 'a`b' 'a\b' 'a<b' 'a;b' 'a|b' 'a&b' \
         'a(b' 'a)b' 'a>b' 'a	b'; do
  alias "$n=v" 2>&1 | e; echo "st=${PIPESTATUS[0]}"
done
alias '=x' '' 2>&1 | e; echo "st=${PIPESTATUS[0]}"
alias -z 2>&1 | e; echo "st=${PIPESTATUS[0]}"
alias --=v 2>&1 | e; echo "st=${PIPESTATUS[0]}"
alias -a=v 2>&1 | e; echo "st=${PIPESTATUS[0]}"
unalias 2>&1 | e; echo "st=${PIPESTATUS[0]}"
unalias -z 2>&1 | e; echo "st=${PIPESTATUS[0]}"
unalias nope zz nope2 2>err; echo st=$?; e <err
alias zz 2>err; echo st=$?; e <err
alias | wc -l
set -o posix
alias q="it's"; alias; alias q; alias -p q
set +o posix
alias q
unalias -a; echo st=$?
alias; echo "none st=$?"

# --- expansion: off by default, posix mode turns it on ---
alias E='echo E:'
E off 2>&1 | e
shopt expand_aliases
set -o posix
E posix 2>&1 | e
shopt expand_aliases
set +o posix
E noposix 2>&1 | e
shopt expand_aliases
shopt -s expand_aliases
X=1 Y=2 E after assigns
'E' sq 2>&1 | e
\E bs 2>&1 | e
E\
 continued

# --- trailing-blank chaining: the outermost finished alias decides ---
alias A='B ' B='echo ' C=c D='B' F='G ' G='echo'
A C
A A C
D C
F C
alias sp='echo ' w=WORD c1='sp c2 ' c2='w'
c1 w
alias echo='echo [e]'
sp echo hi
unalias echo

# --- LINENO after a multi-line alias value; function names ---
alias nl='echo a
echo b'
nl
echo "lineno=$LINENO"
alias fn=realfn
fn() { echo in-realfn; }
realfn
declare -F | sed 's/declare -f //'
