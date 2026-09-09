# A readonly array/assoc rejects element writes: the assignment fails with
# status 1 and the value is unchanged, and the script continues. (stderr carries
# the "readonly variable" message, which this suite does not compare.)

declare -Ar A=([a]=1)
A[a]=2
echo "assoc=${A[a]} st=$?"
A[b]=new
echo "assoc-new=${A[b]:-none} st=$?"

declare -ar I=(10 20)
I[0]=99
echo "idx=${I[0]} st=$?"

# A non-readonly array still works normally.
declare -A m=([k]=1)
m[k]=2
m[j]=3
echo "ok=${m[k]},${m[j]}"
echo done
