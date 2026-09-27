# An arithmetic error in an array literal's indexed subscript is bash's DISCARD in every
# tier: the rest of the line is abandoned and a ( ) subshell exits 1 (arrayfunc.c
# assign_compound_array_list -> array_expand_index -> evalexp). And $PIPESTATUS is set
# after EVERY assignment statement, whatever its outcome: a rejected or line-aborted one
# too (execute_null_command; exp_jump_to_top_level / set_exit_status).
for ((i=0;i<3;i++)); do ( a=([x+]=1); echo no$i ) 2>/dev/null; echo s=$?; done
( declare -a b=([x+]=1); echo no ) 2>/dev/null; echo s=$?
f() { local l=([x+]=1); echo no; }; ( f; echo after ) 2>/dev/null; echo s=$?
( a=([x y]=1); echo no ) 2>/dev/null; echo s=$?
( a=([")"]=1); echo no ) 2>/dev/null; echo s=$?
( a=(1 [x+]=2 3); echo no ) 2>/dev/null; echo s=$?
( a=(1 $((1+)) 3); echo no ) 2>/dev/null; echo s=$?
( eval 'a=([x+]=1)'; echo no ) 2>/dev/null; echo s=$?
a=([x+]=1) 2>/dev/null; echo top-no
echo top s=$?
readonly r=1
declare -n c1=c2 c2=c1
declare -i n
exec 3>&2 2>/dev/null
false | true; x=1
echo a ${PIPESTATUS[@]}
false | true; r=2
echo b ${PIPESTATUS[@]}
false | true; c1=3
echo c ${PIPESTATUS[@]}
false | true; n=1+
echo d ${PIPESTATUS[@]}
false | true; SHELLOPTS=x
echo e ${PIPESTATUS[@]}
false | true; a=([x+]=1)
echo f ${PIPESTATUS[@]}
false | true; r=(1)
echo g ${PIPESTATUS[@]}
false | true; x=1 r=2 y=3
echo h ${PIPESTATUS[@]}
false | true; echo $((1+))
echo i ${PIPESTATUS[@]}
false | true; x=$(exit 3)
echo j ${PIPESTATUS[@]}
eval 'false | true; r=2
echo k ${PIPESTATUS[@]}'
exec 2>&3
# hot: a 150-iteration loop, a function called 150 times, eval text
hot=
for ((i=0;i<150;i++)); do
	( a=([x+]=1); echo no ) 2>/dev/null; hot+=$?
	false | true; x=$i; hot+=${PIPESTATUS[*]}
done
echo ${#hot} ${hot//10/}
g() { false | true; x=$1; p+=${PIPESTATUS[*]}; ( local l=([x+]=1); echo no ) 2>/dev/null; p+=$?; }
p=
for ((i=0;i<150;i++)); do g $i; done
echo ${#p} ${p//01/}
q=
for ((i=0;i<150;i++)); do eval 'false | true; x=$i; q+=${PIPESTATUS[*]}; ( a=([x+]=1); echo no ) 2>/dev/null; q+=$?'; done
echo ${#q} ${q//01/}
k=
for ((i=0;i<150;i++)); do eval 'false | true; r=2
k+=${PIPESTATUS[*]}' 2>/dev/null; done
echo ${#k} ${k//1/}
# select: EOF on a partial last line ends the loop (bash's read fails; REPLY gets the partial)
printf '2\n1' | { select x in a b; do echo "got $x $REPLY"; done 2>/dev/null; echo "s=$? R=$REPLY x=$x"; }
printf '' | { REPLY=z; select x in a b; do :; done 2>/dev/null; echo "s=$? R=$REPLY"; }
