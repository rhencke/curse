# The fuzz campaign's container (tools/fuzz/docker/run.sh; README.md "Docker").
# Only the RUNTIME of a campaign: the harness, gram_mutator.so, luajit, curse and the
# bash oracle are built on the host by meson and bind-mounted read-only (same Debian
# release, so the same glibc and the same AFL++ as the host's afl-cc).
FROM debian:trixie-slim@sha256:a99cfc517144bc59b1978475ec53b46ecabec7e43635402ee5b77cc54cd1b20a
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      afl++=4.21c-5 bash coreutils diffutils findutils grep mawk python3 sed util-linux \
 && rm -rf /var/lib/apt/lists/*
LABEL org.curse.role=fuzz
CMD ["bash"]
