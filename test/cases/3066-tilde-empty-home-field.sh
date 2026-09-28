# The word-initial `~` of an unquoted ${x:+WORD} / ${x:-WORD} operand: bash quotes the
# tilde's expansion, so with HOME='' it is still a (null) field — `${a:+~}` gives one empty
# argument, as a plain `~` does. curse word-split the empty expansion away (fuzz F108).
HOME=; a=(one); x=1
printf '<%s>' ${a:+~} x; echo
printf '<%s>' ~ x; echo
printf '<%s>' ${x:+~} ${u:-~} ${u-~} ${x+~} x; echo
printf '<%s>' ${x:+~/} ${x:+a~} ${x:+~:~} ${x:+~}${x:+~} x; echo
printf '<%s>' "${x:+~}" x; echo
set -- ${x:+~}; echo "n=$#"
HOME=/h; printf '<%s>' ${x:+~} ${x:+~/a b} x; echo; HOME=
f() { printf '<%s>' ${1:+~} f; echo; }; f 1
eval 'printf "<%s>" ${x:+~} e; echo'
printf 'printf "<%%s>" ${x:+~} s; echo\n' > s3066.sh; . ./s3066.sh
trap 'printf "<%s>" ${x:+~} t; echo' USR1; kill -USR1 $$; trap - USR1
i=0; while [ $i -lt 150 ]; do set -- ${x:+~} ${u:-~}; echo "$#"; i=$((i + 1)); done | sort | uniq -c
rm -f s3066.sh
