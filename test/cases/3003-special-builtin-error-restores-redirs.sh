# A special builtin's usage error abandons the rest of the line, and its own redirections
# are undone on the way out (bash's cleanup_redirects unwind-protect): the compiled tier
# left `shift 1 2 2>/dev/null`'s 2>/dev/null in place for the rest of the script (fuzz F91).
# The error is bash's no_args DISCARD: it isn't contained by an eval or a sourced file.
shift 1 2 2>/dev/null; echo not-reached
( nosuch_a )
set -o bogus_opt 2>/dev/null; echo not-reached-2
( nosuch_b )
f() { shift 1 2 2>/dev/null; echo in-f; }
f; echo not-reached-3
( nosuch_c )
eval 'shift 1 2 2>/dev/null'; echo "eval st=$?"
( nosuch_d )
printf 'shift 1 2 2>/dev/null\necho in-src\n' > s3003.sh; . ./s3003.sh; echo not-reached-4
( nosuch_d2 )
eval 'return 1 2 2>/dev/null'; echo not-reached-5
( nosuch_d3 )
rm -f s3003.sh
g() { return 3 2>/dev/null; }; g; echo "g=$?"
( nosuch_e )
for i in 1 2; do break 2>/dev/null; done; echo "for=$i"
( nosuch_f )
h() { shift 1 2 2>/dev/null; }
i=0; while [ $i -lt 150 ]; do
	( h; echo not-reached-6 )
	i=$((i + 1))
done
echo "i=$i" >&2
( nosuch_g )
