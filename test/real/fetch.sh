#!/usr/bin/env bash
# Fetch a curated set of real-world shell scripts into test/real/fetched/
# (gitignored — third-party, not committed). Run inside the dev image via ./x so
# it works regardless of host tooling: `./x bash /work/test/real/fetch.sh`.
# Uses Node's built-in fetch, so no curl/wget needed.
set -u
dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fetched"
mkdir -p "$dir"

# name<TAB>url  — pinned where possible for reproducibility.
grab() {
  local name="$1" url="$2"
  node -e '
    const [, url, out] = process.argv;
    fetch(url, { redirect: "follow" })
      .then((r) => { if (!r.ok) throw new Error("HTTP " + r.status); return r.text(); })
      .then((t) => require("fs").writeFileSync(out, t))
      .catch((e) => { console.error(e.message); process.exit(1); });
  ' "$url" "$dir/$name" && echo "  got $name ($(wc -l < "$dir/$name") lines)" || echo "  FAILED $name"
}

grab nvm-install.sh       https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh
grab rustup-init.sh       https://raw.githubusercontent.com/rust-lang/rustup/1.27.1/rustup-init.sh
grab wait-for-it.sh       https://raw.githubusercontent.com/vishnubob/wait-for-it/81b1373f17855a4dc21156cfe1694c31d7d1792e/wait-for-it.sh
grab git-completion.bash  https://raw.githubusercontent.com/git/git/v2.45.0/contrib/completion/git-completion.bash
grab starship-install.sh  https://raw.githubusercontent.com/starship/starship/v1.20.1/install/install.sh
grab shunit2              https://raw.githubusercontent.com/kward/shunit2/v2.1.8/shunit2
grab get-docker.sh        https://raw.githubusercontent.com/docker/docker-install/master/install.sh
grab n.sh                 https://raw.githubusercontent.com/tj/n/v10.1.0/bin/n
grab deno-install.sh      https://raw.githubusercontent.com/denoland/deno_install/master/install.sh
grab pyenv-installer.sh   https://raw.githubusercontent.com/pyenv/pyenv-installer/master/bin/pyenv-installer
grab homebrew-install.sh  https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh
grab bats-core.sh         https://raw.githubusercontent.com/bats-core/bats-core/v1.11.0/libexec/bats-core/bats
echo "fetched into $dir"
