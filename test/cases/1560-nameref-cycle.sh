# A circular nameref chain (ref1 -> ref2 -> ref1) is detected: bash warns to
# stderr (not compared here) and treats the reference as unset on read (empty)
# and rejects a write with status 1. Execution continues.
typeset -n ref1=ref2
typeset -n ref2=ref1
echo defined

echo "read1=[$ref1]"
echo "read2=[${ref2}]"

ref1=z 2>/dev/null
echo "write-status=$?"

# a non-circular nameref still resolves normally
target=hello
typeset -n good=target
echo "good=[$good]"
good=world
echo "target=[$target]"
