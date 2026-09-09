# printf '%(FORMAT)T' formats a timestamp with strftime. Uses a fixed epoch in
# UTC so the result is deterministic (and agrees with the oracle regardless of
# installed timezone data).
export TZ=UTC

ts=1557978599   # 2019-05-16 03:49:59 UTC

printf '%(%Y-%m-%d)T\n' "$ts"
printf '%(%H:%M:%S)T\n' "$ts"
printf '%(%A, %B %d, %Y)T\n' "$ts"
printf 'year=%(%Y)T\n' "$ts"

# Width and precision apply to the formatted string.
printf '[%12.7(%Y-%m-%d)T]\n' "$ts"

# Literal %% inside the format.
printf '%(100%%)T\n' "$ts"
