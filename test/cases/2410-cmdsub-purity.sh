# A $(…) body is a subshell: `command`/`builtin` in front of a state-changing builtin must
# not reach the parent shell (curse once judged purity twice — the interpreter's denylist
# missed the prefixes, so cold and compiled runs of one script differed).
cd /tmp
x=$(command cd /); pwd
x=$(builtin cd /); pwd
x=$(command export CMDSUB_Q=1); echo "q=[$CMDSUB_Q]"
x=$(builtin set -f); case $- in *f*) echo "noglob leaked" ;; *) echo "noglob kept" ;; esac
x=$(printf -v CMDSUB_V %s 1; echo "in=$CMDSUB_V"); echo "$x out=[$CMDSUB_V]"
# $RANDOM is reseeded per subshell: the parent's sequence doesn't advance
RANDOM=1; r1=$RANDOM; RANDOM=1; x=$(echo $RANDOM); r2=$RANDOM
[ "$r1" = "$r2" ] && echo "random kept" || echo "random advanced"
# pure bodies still work: pipelines, and-or lists, externals
x=$(echo a | tr a b); echo "[$x]"
x=$(true && echo yes || echo no); echo "[$x]"
f() { echo f; }; x=$(echo a | f); echo "[$x]"
# A body is light (no checkpoint) only when nothing in it can change the shell: no
# assigning/indirect/arithmetic expansion anywhere in its words, no printf -v (even one a
# variable expands to), no function — also one the compiler couldn't see (a fragment's
# partial function table, an eval-defined or env-imported function). Each case must leave
# the parent untouched at top level, in a hot loop, in eval / trap text / a sourced file,
# and in functions called 150 times (plain and eval-defined).
f() { g=$((g+1)); echo f$g; }
rep() { echo "$1: a=${a-u} z=${z-u} q=${q-u} g=${g-u} n=${n-u} q2=${q2-u} a1=${a1[0]-u} a6=${a6-u} bp=${bp-u}"
	unset a z q g n q2 a1 a6 bp; }
v=BASHPID o=-v
x=$(true && echo ${a:=1}); x=$(echo ${z:=5}); x=$(printf -vq %s hi); x=$(true && f)
x=$(echo $((n++))); x=$(printf $o q2 %s x); x=$(true ${a1[0]=q}); x=$(pwd ${a6:=1})
x=$(echo ${!v}); [ "$x" = "$$" ] && bp=same
rep top
for ((i = 0; i < 150; i++)); do
	x=$(true && echo ${a:=1}); x=$(echo ${z:=5}); x=$(printf -vq %s hi); x=$(true && f)
	x=$(echo $((n++))); x=$(printf $o q2 %s x); x=$(true ${a1[0]=q}); x=$(pwd ${a6:=1})
	x=$(echo ${!v}); [ "$x" = "$$" ] && bp=same
done
rep loop
fn() {
	x=$(true && echo ${a:=1}); x=$(echo ${z:=5}); x=$(printf -vq %s hi); x=$(true && f)
	x=$(echo $((n++))); x=$(printf $o q2 %s x); x=$(true ${a1[0]=q}); x=$(pwd ${a6:=1})
	x=$(echo ${!v}); [ "$x" = "$$" ] && bp=same
}
for ((i = 0; i < 150; i++)); do fn; done
rep func
B='x=$(true && echo ${a:=1}); x=$(echo ${z:=5}); x=$(printf -vq %s hi); x=$(true && f)
x=$(echo $((n++))); x=$(printf $o q2 %s x); x=$(true ${a1[0]=q}); x=$(pwd ${a6:=1})
x=$(echo ${!v}); [ "$x" = "$$" ] && bp=same'
eval "$B"; rep eval
trap "$B" USR1; kill -USR1 $$; kill -USR1 $$; trap - USR1; rep trap
T=$(mktemp); echo "$B" > "$T"; . "$T"; rep source; rm -f "$T"
eval "ef() { $B
}"
for ((i = 0; i < 150; i++)); do ef; done; rep evalfn
# a function defined after the body was compiled (eval), and one imported from the
# environment shadowing a pure builtin
for ((i = 0; i < 150; i++)); do [ $i = 100 ] && eval 'late() { g=$((g+1)); }'; x=$(late); done 2>/dev/null
rep late
env 'BASH_FUNC_pwd%%=() { n=$((n+1)); }' ${THIS_SH:-bash} -c 'for i in {1..150}; do x=$(pwd); done; echo "import: n=${n-u}"'
# common light bodies still give their output
y=abc.d; x=$(echo "${y%.*}" "${#y}" ${y:-q} "$y" | tr a A); echo "[$x]"
x=$(printf %s "$y"); echo "[$x]"
