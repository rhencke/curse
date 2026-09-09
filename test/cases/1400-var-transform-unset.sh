# A ${name@op} transform on an unset scalar produces no field (so unquoted it
# drops out of the argument list), while a set-but-empty value still transforms;
# under set -u an unset transform is a fatal error.

x=x
empty=
# undef contributes nothing between the two x's -> three words, not four.
set -- ${x@Q} ${undef@Q} ${x@Q}
echo "count=$# args=$*"

# A set-but-empty value transforms to '' (not dropped).
echo "empty=[${empty@Q}] undef=[${undef@Q}]"

# @a attribute letters: set-empty and unset are both empty; a readonly shows r.
declare -r ro=v
echo "attrs=[${ro@a}][${empty@a}][${undef@a}]"

# Under set -u, transforming an unset variable aborts; run in a subshell (which
# exits 1, not 127) so the script continues.
set -u
( echo "${undef@Q}" ) 2>/dev/null
echo "nounset=$?"
echo done
