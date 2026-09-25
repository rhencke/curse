# brace expansion, from bash's braces.c: sequences (steps, direction, a zero
# step, zero padding to the widest endpoint — its width counting a `-`, as
# %0*d does), character ranges (across the ASCII punctuation between Z and
# a), invalid sequences left alone, comma lists (nesting, empty members,
# quoting and escapes, ${…} and $x untouched), 64-bit bounds, set +B.
p() { printf '[%s]' "$@"; echo; }
p {1..5} {5..1} {-2..2} {1..10..3} {10..1..-3} {1..10..-3} {1..1} {1..2..0}
p {01..10..3} {-05..5..5} {1..010} {001..3} {a..e} {e..a} {a..k..3} {Z..c} {A..z..10}
p {a..1} {1..a} {1.5..3} {1..3..1.5} {1..3..} {..3} {a..} {x} {} {,} {,a} {a,}
p a{b,c}d{e,f} {a,b}{1..2} {{a,b},{c,d}} {a,{b,c}d}e x{a,b{1..3}}y
p '{a,b}' "{a,b}" \{a,b} {a\,b,c} {a,b\} {'a,b',c} {"a b",c} {a..c}'x' \{1..3}
p ${x-{a,b}} {a,$y} a{,}b {a,,b} {{1..2}} {1..3}{a,b} {a..c..-1}
p {9223372036854775806..9223372036854775807} {-9223372036854775808..-9223372036854775807}
p {2147483646..2147483648} {1..3..9223372036854775807}
x=5; p {1..$x} {a,b}$x
set -- q r; p {"$@",z}
p {\\,a} {\$,a} {a,b,c}[123] {,,}
p ~{a,b} a={b,c} {a=b,c}
set +B; p {a,b} {1..3}; set -B
p {a..c}{1..2}{x,y}
p() { printf "[%s]" "$@"; echo; }
p {-05..5..5} {1..-05} {-01..1} {-1..01} {-010..2..4} {00..-2}
