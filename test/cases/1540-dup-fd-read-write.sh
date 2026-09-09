# `N>&M` and `N<&M` both duplicate fd M onto fd N — the direction glyph only
# signals intent, the dup is identical. So `1<&2` sends fd 1 to wherever fd 2
# points, exactly like `1>&2`.
echo out-to-err 1>&2
echo also-to-err 1<&2
# 2<&1 / 2>&1 both send fd 2 to fd 1 (stdout)
echo err-to-out-a 2>&1
echo err-to-out-b 2<&1
