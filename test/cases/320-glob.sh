cd "$(mktemp -d)"
touch a.txt b.txt c.log a.md
mkdir sub
touch sub/one.txt sub/two.txt

echo "txt: "*.txt
echo "all: "*
echo "log: "*.log
echo "sub: "sub/*.txt
echo "class: "[ab].txt
echo "q: "?.md
echo "nomatch: "*.zzz
echo "quoted: ""*.txt"
echo "single: "'*'
for f in *.txt; do echo "loop: $f"; done
count=(*.txt)
echo "arraycount: ${#count[@]}"
