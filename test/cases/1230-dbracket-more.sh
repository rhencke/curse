# [[ ]]: trailing redirects, ! as an operand, tilde in patterns, =~ regex errors

# a trailing redirect on a conditional
[[ -n hello ]] 2>/dev/null; echo "r1=$?"
[[ abc == a* ]] >/dev/null; echo "r2=$?"

# an unquoted ! on the right of == is a literal (negation is term-leading only)
[[ '!' == ! ]] && echo "bang-eq"
[[ x != ! ]] && echo "bang-ne"

# tilde in [[ ]] patterns expands to $HOME
HOME=/home/me
[[ /home/me == ~ ]] && echo "tilde-eq"
[[ /home/me/file == ~/* ]] && echo "tilde-glob"
[[ ~ == /home/me ]] && echo "tilde-lhs"

# =~ regex matching, and an invalid regex yields status 2
[[ foobar =~ o+b ]] && echo "re-match"
[[ x =~ * ]]; echo "re-bad=$?"
[[ y =~ ^y$ ]]; echo "re-ok=$?"

# && binds tighter than || (compound expression, tight whitespace)
[[ '' || 1 == 1 ]] && echo "compound"
