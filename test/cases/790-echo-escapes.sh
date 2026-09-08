# echo -e backslash escapes: hex, unicode, octal

# \xHH hex (one or two digits)
echo -e 'a\x65b'
echo -e 'A\x42\x43D'
# incomplete / invalid hex stays literal
echo -e 'a\x6z'
echo -e 'end\xg'
echo -e 'bare\x'

# \uHHHH (up to 4) and \UHHHHHHHH (up to 8): Unicode code points
echo -e '\u0041\u0042\u0043'
echo -e '\U00000044'
echo -e 'part\u006one'
# multibyte code points round-trip as UTF-8, matching bash's bytes
echo -e 'café'
echo -e 'grin \U0001F600 done'
# invalid/empty unicode stays literal
echo -e 'x\uy'
echo -e 'z\U'

# \0NNN octal (leading zero required); \NNN without it is literal
echo -e '\0101\0102'
echo -e 'no\101'

# control chars via od so they compare cleanly
echo -en 'p\x06q' | od -A n -c | sed 's/  */ /g'
echo -en 'r\x00s' | od -A n -t x1 | sed 's/  */ /g'

# escapes also flow through printf %b
printf '%b\n' 'x\x41y'
printf '%b\n' 'u\x42v'
