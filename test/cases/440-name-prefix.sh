# ${!prefix*} / ${!prefix@} — names of set variables sharing a prefix.
# Use a unique prefix so only vars this script sets can match.
zzq_beta=2
zzq_alpha=1
zzq_gamma=3
other=ignored

echo "star: ${!zzq_*}"
echo "at:" ${!zzq_@}

# quoted @ keeps each name a field; ${!n} then reads each var indirectly
for n in "${!zzq_@}"; do
  echo "name=$n value=${!n}"
done

# collect into an array
sorted=("${!zzq_@}")
echo "count: ${#sorted[@]} first: ${sorted[0]} last: ${sorted[2]}"

# no matches -> empty
echo "none: [${!nomatch_*}]"
empty=(${!nomatch_@})
echo "empty count: ${#empty[@]}"
