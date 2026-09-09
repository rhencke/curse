# Inside backticks, a backslash is dropped before ` $ \ — and, when the backticks
# are themselves inside double quotes, before " as well (unlike $(), which keeps
# it). This is the classic difference bash's manual warns about.

echo "a $(echo hi) b"
echo "a $(echo "hi") b"
echo "a $(echo \"hi\") b"      # $(): backslash kept -> "hi"
echo "a `echo hi` b"
echo "a `echo "hi"` b"
echo "a `echo \"hi\"` b"       # backtick in "": backslash dropped -> hi
echo `echo \"hi\"`             # backtick unquoted: backslash kept -> "hi"
