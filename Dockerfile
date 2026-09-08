# syntax=docker/dockerfile:1

# Dev builder image for the "curse" project.
#
#   base   : Debian 13 "trixie" (matches the host)
#   bash   : from trixie (5.2.x) -- "good enough"
#   node   : latest from NodeSource
#            NODE_MAJOR=24 -> LTS "Krypton" (default)
#            NODE_MAJOR=26 -> Current line

FROM debian:trixie-slim

ARG NODE_MAJOR=24

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    SHELL=/bin/bash

# Keep apt's downloads in the BuildKit cache mounts for fast rebuilds.
RUN rm -f /etc/apt/apt.conf.d/docker-clean \
 && echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' \
      > /etc/apt/apt.conf.d/keep-cache

# Base tooling + bash (from trixie) + NodeSource prerequisites.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update \
 && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        curl \
        gnupg \
        git \
        build-essential \
        pkg-config

# Node.js from the modern NodeSource "nodistro" apt repo.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    install -m 0755 -d /etc/apt/keyrings \
 && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
      | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg \
 && chmod a+r /etc/apt/keyrings/nodesource.gpg \
 && echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
      > /etc/apt/sources.list.d/nodesource.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends nodejs

SHELL ["/bin/bash", "-c"]

# Bake a sanity check into the build so a broken image fails here.
RUN bash --version | head -n1 \
 && node --version \
 && npm --version

WORKDIR /work
CMD ["bash"]
