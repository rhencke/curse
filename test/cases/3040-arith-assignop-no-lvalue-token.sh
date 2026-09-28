# Where an operand belongs, bash's readtok reads `+=`, `-=` and `!=` as ONE token, so an
# operand-expected error names the text from that token on (`+=*63-1`, not `=*63-1`);
# curse read a sign or `!` and then failed at the `=` (fuzz F99).
# (POSIX $(( )): dash errors too — with its own status and message; stdout says only "err")
t() { local e=$1; ( echo "$(( $e ))" ) || echo err; }
t '+=*63-1'
t '2*+=3-1'
t '2**+=-1'
t '2*-=3'
t '-=1'
t '2*!=3'
t '!=1'
t '2*-+=3'
t '2*==3'
( (( 2*+=3 )) ) || echo "arith err"
( let '1-=2' ) || echo "let err"
eval 'e=+=5; ( echo $(( $e )) ) || echo "eval err"'
printf 'e="1+ -=2"; echo $(( $e ))\n' > s3040.sh; ( . ./s3040.sh ) || echo "src err"
trap 't "3*+=4"' USR1; kill -USR1 $$; trap - USR1
i=0; while [ $i -lt 150 ]; do t "$i*+=1"; i=$((i + 1)); done
rm -f s3040.sh
