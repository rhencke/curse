echo {a,b,c}
echo pre{1,2,3}post
echo {1..5}
echo {5..1}
echo {a..e}
echo {1..10..2}
echo {01..05}
echo x{a,b}y{1,2}z
echo file.{txt,md,json}
echo nested{a,b{c,d}}
echo "{a,b}" literal
echo no{brace}here
for i in {1..3}; do echo "i=$i"; done
printf '<%s>' {a,b,c}
printf '\n'
