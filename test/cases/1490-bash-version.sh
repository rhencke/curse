# curse claims to be the bash version it targets, so scripts that gate features
# on $BASH_VERSION / $BASH_VERSINFO treat it as bash.
[[ -n $BASH_VERSION ]] && echo "have BASH_VERSION"
echo "major.minor=${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"
echo "release=${BASH_VERSINFO[4]}"
echo "vinfo count=${#BASH_VERSINFO[@]}"
echo "full=$BASH_VERSION"

# The nvm/rustup-style guard: refuse if not bash.
if [ -z "${BASH_VERSION}" ]; then echo "not bash"; else echo "is bash"; fi
