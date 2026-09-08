declare -A color
color[apple]=red
color[banana]=yellow
color[grape]=purple
echo "apple is ${color[apple]}"
echo "banana is ${color[banana]}"
echo "count: ${#color[@]}"

# iterate keys (sorted for determinism)
for k in $(echo "${!color[@]}" | tr ' ' '\n' | sort); do
  echo "$k -> ${color[$k]}"
done

# key with a variable
which=grape
echo "picked: ${color[$which]}"

# append to a value
color[apple]+=dish
echo "apple now: ${color[apple]}"

# missing key
echo "missing: [${color[cherry]}]"

# assoc populated by element assignments
declare -A caps
caps[usa]=dc
caps[france]=paris
echo "caps count: ${#caps[@]}"
echo "france: ${caps[france]}"

# values (sorted)
echo "colors:"
for v in $(echo "${color[@]}" | tr ' ' '\n' | sort); do echo "  $v"; done
