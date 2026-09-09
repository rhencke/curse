# `times` prints two lines (shell then children), each two `%dm%.3fs` fields.
# The CPU values themselves are nondeterministic, so assert the shape, not the
# numbers — that stays identical between bash and curse.
times | while read -r a b; do
  if [[ $a =~ ^[0-9]+m[0-9]+\.[0-9]+s$ && $b =~ ^[0-9]+m[0-9]+\.[0-9]+s$ ]]; then
    echo ok
  fi
done
echo "lines=$(times | wc -l)"
