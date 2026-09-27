# A syntax error at the END of a $( … ) body is at its closing `)`: reported on the body's
# last line (not one past it), and when that line is a source line of its own, bash shows
# the whole source line — the text after the `)` too.
S=${THIS_SH:-bash}
t=${TMPDIR:-/tmp}/c2590.$$; mkdir -p "$t"; cd "$t" || exit 1
e() { sed 's/^[^:]*: line \([0-9]*\): /L\1: /'; }
r() { printf '%b' "$1" > s.sh; $S s.sh 2>&1 | e; echo "st=${PIPESTATUS[0]}"; }
r 'echo a; echo "$(if)"; echo b\necho c'
r 'echo a; echo $(if); echo b\necho c'
r 'echo "$(if\n)"; echo b\necho c'
r 'echo "$(echo\nif\n\n)" x\necho c'
r 'x=${y:-$(echo;\nfi)} z\necho c'
r 'echo $(echo\n  fi) q\necho c'
r 'echo "$(echo;\nfi\necho)"\necho c'
cd / && rm -rf "$t"   # (leave nothing behind in $TMPDIR)
