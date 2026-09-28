# Pinned bash behaviour: a $( … ) in an expanding here-document body that never closes is
# parsed as bash's parse_comsub reads it: a syntax error met before the end of the body is
# reported like the reader's own (`near unexpected token`, then the line) at its line, counted
# from the line after the command; running out of body is the EOF error at its last line.
cat <<X
$( fi )
X
echo after1
cat <<X
a $( if; ) b
X
echo after2
cat <<X
$( fi
X
echo after3
cat <<X
line1
line2 $( echo hi
more
X
echo after3
cat <<X
l1
$( ec; fi
X
echo after4
f() {
cat <<X
1
2 $( ;
X
}
f
cat <<X
$( echo a
b; fi
c
X
echo after
for i in 1 2; do cat <<X
$( done
X
done
for ((i = 0; i < 150; i++)); do
	cat <<X
$( ec; fi
X
done 2>&1 | sort | uniq -c
