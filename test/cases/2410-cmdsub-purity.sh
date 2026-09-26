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
