# shopt, from bash's builtins/shopt.def: listings (all, -p, -o, -s/-u filters),
# queries (-q, several names, invalid names), setting several names, -s with
# -u, -o for the set options, options ending at the first operand or `--`, and
# the compatNN options tied to $BASH_COMPAT both ways (set_compatibility_level,
# sv_shcompat: unsetting one binds the resulting level).
e() { sed 's/^.*line [0-9]*: //'; }
shopt | md5sum; shopt | wc -l
shopt -p | md5sum
shopt -o | md5sum; shopt -po | md5sum
shopt -s | md5sum; shopt -u | wc -l
shopt -so; shopt -uo | wc -l
shopt nullglob extglob
shopt -p nullglob extglob
shopt -q nullglob; echo "q off st=$?"; shopt -q extquote; echo "q on st=$?"
shopt -q extquote nullglob; echo "q mixed st=$?"; shopt -q extquote bogus 2>&1 | e; echo "q bogus st=${PIPESTATUS[0]}"
shopt bogus 2>&1 | e; echo "bogus st=${PIPESTATUS[0]}"
shopt -s bogus nullglob 2>&1 | e; echo "st=${PIPESTATUS[0]}"; shopt -s bogus nullglob 2>/dev/null; shopt -p nullglob; shopt -u nullglob
shopt -su nullglob 2>&1 | e; echo "su st=${PIPESTATUS[0]}"
shopt -x 2>&1 | e; echo "x st=${PIPESTATUS[0]}"
shopt -s login_shell 2>&1 | e; echo "login st=${PIPESTATUS[0]}"; shopt -p login_shell
shopt -s restricted_shell 2>&1 | e; echo "rs st=${PIPESTATUS[0]}"; shopt -p restricted_shell
shopt -o errexit nounset; shopt -po errexit
shopt -so nounset; echo "$-"; shopt -uo nounset; echo "$-"
shopt -o bogus 2>&1 | e; echo "o bogus st=${PIPESTATUS[0]}"
shopt -qo nounset; echo "qo st=$?"; shopt -qo errexit bogus 2>&1 | e
shopt -s compat31 2>&1 | e; echo "compat31 st=${PIPESTATUS[0]}"; shopt -p compat31; echo "BASH_COMPAT=${BASH_COMPAT-unset}"; shopt -u compat31; echo "BASH_COMPAT=${BASH_COMPAT-unset}"
BASH_COMPAT=44; shopt -p compat44; unset BASH_COMPAT; shopt -p compat44
shopt -s nullglob dotglob; shopt -p nullglob dotglob; shopt -u nullglob dotglob
shopt -s -- nullglob; shopt -p nullglob; shopt -u nullglob
shopt -p -o pipefail; shopt -s -o pipefail; shopt -p -o pipefail; set +o pipefail
echo "$BASHOPTS" | tr ':' '\n' | head -5
shopt -s compat43; shopt -p compat43 compat44; echo "B=$BASH_COMPAT"; shopt -u compat44; echo "B=$BASH_COMPAT"; shopt -u compat43; echo "B=$BASH_COMPAT"; BASH_COMPAT=50; shopt -u compat44; echo "B=$BASH_COMPAT"; BASH_COMPAT=4.2; shopt -p compat42; BASH_COMPAT=99; shopt -p compat42 2>&1; shopt nullglob -s
