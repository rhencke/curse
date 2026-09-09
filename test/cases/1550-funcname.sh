# FUNCNAME exposes the running bash function and its callers: [0] is the current
# function, [1] its caller. Plain $FUNCNAME is [0], and it is unset at the top
# level. (bash also appends a "main" base frame when run from a script file but
# not from -c; that mode-dependent frame is intentionally not asserted here.)
echo "top=[${FUNCNAME:-none}] set=[${FUNCNAME+yes}]"

inner() {
  echo "inner: name=$FUNCNAME [0]=${FUNCNAME[0]} [1]=${FUNCNAME[1]}"
}
outer() { inner; }
outer

echo "after=[${FUNCNAME:-none}]"

# indirect reference to FUNCNAME resolves the running function
show() { local r=FUNCNAME; echo "indirect=${!r}"; }
show
