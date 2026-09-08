# ANSI-C quoting
echo $'tab\tend'
echo $'line1\nline2'
echo $'quote\'inside'
echo $'hex\x41\x42'
echo $'oct\101\102'
printf '%s\n' $'a\tb'

# locale strings (no translation)
echo $"locale string"

# tilde expansion
echo ~
echo ~/subdir
p=~/bin
echo "$p"

# quoted tilde does not expand
echo "~"
echo '~'
echo \~
