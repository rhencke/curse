# A syntax error at a token where the line's command list could end, on a line that opened
# here-documents: bash's reduction to simple_list gathers their bodies first — their EOF
# warnings come before the error, reported at the last line read, showing the command's
# line (fuzz F50). Inside an unfinished command (`cat <<E && ;`) it reports at once.
e() { eval "$1"; echo "st $?"; }
e 'cat <<EOF; }
x'
e 'cat <<EOF; } x
x'
e 'cat <<EOF )
x
EOF'
e 'cat <<EOF ;;
x
EOF'
e 'cat <<EOF & }
x
EOF'
e 'cat <<EOF; echo a b )
x
EOF'
e 'cat <<EOF && ;
x
EOF'
e 'cat <<EOF | )
x
EOF'
e 'cat <<EOF; echo a && ;
x
EOF'
e '{ cat <<EOF; ) }
x
EOF'
e 'cat <<A <<B; fi
a
A
b'
printf 'cat <<EOF; fi\nx\nEOF\necho after\n' > s2748.sh; . ./s2748.sh; echo "source $?"
trap 'eval "cat <<EOF; }
t"' USR1; kill -USR1 $$; trap - USR1
i=0; while [ $i -lt 150 ]; do eval 'cat <<EOF; done
b
EOF'; i=$((i + 1)); done 2>&1 | sort | uniq -c
rm -f s2748.sh
