# getopts corners per bash's builtins/getopts.def (dogetopts) + builtins/getopt.c
# (sh_getopt) + variables.c (OPTIND is created -i, OPTERR=1, sv_optind uses atoi):
# `--` before the optstring, OPTIND's integer attribute, OPTERR's initial value,
# the ':'-in-silent-optstring quirk, OPTARG left declared-but-unset by a flag,
# readonly NAME / OPTARG / OPTIND, NAME with array/integer attributes,
# prefix assignments to OPTARG/OPTIND, silent-mode errors with an invalid NAME.
BASH_ARGV0=prog   # sh_getopt's diagnostics are "$0: illegal option -- x"
e() { "$@" 2>err; local s=$?; sed 's/^.*line [0-9]*: //' err; return $s; }

# OPTIND is an integer variable (declare -i); OPTERR starts as "1"
declare -p OPTIND OPTERR

# getopts' own option parsing (internal_getopt) accepts `--` before OPTSTRING
getopts -- ab o -a; echo "dd st=$? o=$o"
e getopts -q ab o; echo "badopt st=$?"

# OPTIND arithmetic on assignment
set -- -a -b -c x
OPTIND=1+1; getopts abc o; echo "1+1: o=$o OPTIND=$OPTIND"
n=2; OPTIND=n; getopts abc o; echo "n: o=$o OPTIND=$OPTIND"
OPTIND=0x2; getopts abc o; echo "0x2: o=$o OPTIND=$OPTIND"
OPTIND=1; OPTIND+=2; getopts abc o; echo "+=2: o=$o OPTIND=$OPTIND"
OPTIND=; echo "empty=[$OPTIND]"
OPTIND=' 3 '; echo "spaces=[$OPTIND]"

# a flag with no argument leaves OPTARG declared but valueless (bind_variable NULL)
unset OPTARG; OPTIND=1; getopts a o -a; declare -p OPTARG
export OPTARG=x; OPTIND=1; getopts a o -a; declare -p OPTARG; export -n OPTARG
# EOF unbinds it entirely
OPTIND=1; getopts a o z; e declare -p OPTARG

# leading "::" -- only one ':' is stripped, sh_getopt then returns ':' itself,
# so dogetopts takes the success path: NAME=':' and OPTARG=""
OPTIND=1; getopts '::a:' o -a; echo "st=$? o=$o"; declare -p OPTARG
OPTIND=1; getopts '::a:' o -x; echo "st=$? o=$o OPTARG=$OPTARG"

# silent mode with an invalid NAME: OPTARG is still set, status 1
OPTIND=1; e getopts :a: 'b-n' -a; echo "st=$? OPTARG=$OPTARG"
OPTIND=1; e getopts :a: 'b-n' -x; echo "st=$? OPTARG=$OPTARG"

# NAME honors its attributes: -i evaluates, arrays get element [0]
declare -i ni=5; OPTIND=1; getopts ab ni -b; echo "ni=$ni"
declare -a ar=(x y); OPTIND=1; getopts ab ar -b; declare -p ar
declare -A as; OPTIND=1; getopts ab as -b; declare -p as
declare -i OPTARG; OPTIND=1; getopts a: o -a 2+3; echo "OPTARG=$OPTARG"; unset OPTARG

# readonly NAME: every bind fails with a diagnostic, including at EOF (status 1)
( readonly RO=x; set -- -a; OPTIND=1
  getopts a RO; echo "st=$? RO=$RO"
  getopts a RO; echo "eof st=$? RO=$RO" ) 2>&1 | sed 's/^.*line [0-9]*: //'

# readonly OPTARG: the diagnostic is printed but NAME is still bound normally
( OPTIND=1; OPTARG=keep; readonly OPTARG; getopts a:b o -a val; echo "st=$? o=$o OPTARG=$OPTARG" ) 2>&1 | sed 's/^.*line [0-9]*: //'
( OPTIND=1; OPTARG=keep; readonly OPTARG; getopts a:b o -b; echo "st=$? o=$o OPTARG=${OPTARG-unset}" ) 2>&1 | sed 's/^.*line [0-9]*: //'
( OPTIND=1; OPTARG=keep; readonly OPTARG; getopts :a:b o -a; echo "st=$? o=$o OPTARG=$OPTARG" ) 2>&1 | sed 's/^.*line [0-9]*: //'
( OPTIND=1; OPTARG=keep; readonly OPTARG; getopts :a:b o -x; echo "st=$? o=$o OPTARG=$OPTARG" ) 2>&1 | sed 's/^.*line [0-9]*: //'

# readonly OPTIND: the variable can't change, but getopts' internal index still advances
( set -- -a -b -c; OPTIND=1; readonly OPTIND
  getopts abc o; echo "st=$? o=$o OPTIND=$OPTIND"
  getopts abc o; echo "st=$? o=$o OPTIND=$OPTIND" ) 2>&1 | sed 's/^.*line [0-9]*: //'

# diagnostics use $0 even with explicit args inside a function
f() { OPTIND=1; getopts b: o -x -b; getopts b: o -x -b; }
e f; OPTERR=0; f; echo "quiet st=$?"; OPTERR=1
