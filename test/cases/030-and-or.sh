true && echo t-ran
false && echo should-not-print
false || echo f-fallback
true || echo should-not-print-2
false && echo a || echo b
true && echo c || echo d
