# ${!ref} indirect expansion: operators, positional/special, elements

# indirect to a plain variable, with and without a default operator
x=foo
ref=x
echo "a=${!ref}"
echo "b=${!ref-default}"
unset x
echo "c=${!ref-default}"

# operator applies to the referenced target
x=hello
echo "up=${!ref^^}"
echo "sub=${!ref/l/L}"
echo "len=${#x}"

# indirect to positional parameters
set -- one two three
r1=1; r2=3
echo "p1=${!r1}"
echo "p3=${!r2}"

# indirect to a special parameter
false
q='?'
echo "q=${!q}"
n='#'
echo "n=${!n}"

# indirect to an array element
arr=(zero one two)
er='arr[2]'
echo "elem=${!er}"

# indirect to all array elements
allr='arr[@]'
echo "all=${!allr}"

# indirect combined with :- when the target is empty vs unset
empty=''
eref=empty
echo "e1=${!eref:-was-empty}"
echo "e2=${!eref-not-empty}"

# ${!prefix@} name listing still works alongside indirect
PFX_a=1; PFX_b=2
echo "names=${!PFX_@}"
