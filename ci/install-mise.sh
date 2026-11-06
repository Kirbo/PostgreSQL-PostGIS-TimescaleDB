#!/bin/sh
# install-mise.sh — put a PINNED, checksum-verified mise on PATH in a Linux CI job.
#
#   sh ci/install-mise.sh && export PATH="${HOME}/.local/bin:${PATH}"
#   mise install --locked <tool>…
#
# The CI job images (docker:<ver>-cli, alpine) carry no mise. Jobs that run a tool outside their
# pinned image (jq in `compose test`, fnox + age in the jobs that read secrets) install this mise
# first, then take the tool from mise.lock in locked mode — exact version, URL and sha256. Never
# `curl https://mise.run | sh`: that runs whatever the URL serves at job time, in jobs that hold
# the Docker Hub and repo-write tokens.
#
# The static musl build, so it runs on Alpine (the CI images) and glibc alike; x86_64 and aarch64
# (the Mac Mini runner's containers). Needs wget or curl, and sha256sum.
#
# RE-PIN (/maintain, when a newer mise is wanted — a release at least a day old):
#   V=vYYYY.M.P
#   curl -fsSL "https://github.com/jdx/mise/releases/download/$V/SHASUMS256.txt" \
#     | grep -E "mise-$V-linux-(x64|arm64)-musl\$"
#   …cross-check one hash against a fresh download of the asset itself, and keep the version
#   at or above mise.toml's min_version.
set -eu

MISE_VERSION="v2026.11.2"
case "$(uname -m)" in
  x86_64 | amd64)
    ARCH=x64
    SHA256=fa4f10af83e7131854ceecdf909fc4e4717c8b4d4eb921cf38451d61f118d267
    ;;
  aarch64 | arm64)
    ARCH=arm64
    SHA256=f9036b9cd99f9ca6df130b60bb457d3eda7fbc09d8c0242dc4d819f4410a4b91
    ;;
  *)
    echo "install-mise: unsupported architecture $(uname -m)" >&2
    exit 1
    ;;
esac

DEST="${HOME}/.local/bin/mise"
mkdir -p "$(dirname "${DEST}")"
URL="https://github.com/jdx/mise/releases/download/${MISE_VERSION}/mise-${MISE_VERSION}-linux-${ARCH}-musl"
if command -v curl >/dev/null 2>&1; then
  curl -fsSL --retry 3 -o "${DEST}.tmp" "${URL}"
else
  # busybox wget (the Alpine images) has no retry flag.
  wget -q -O "${DEST}.tmp" "${URL}" || { sleep 2; wget -q -O "${DEST}.tmp" "${URL}"; } ||
    { sleep 5; wget -q -O "${DEST}.tmp" "${URL}"; }
fi
GOT=$(sha256sum "${DEST}.tmp" | cut -d' ' -f1)
if [ "${GOT}" != "${SHA256}" ]; then
  echo "install-mise: mise ${MISE_VERSION} (${ARCH}) checksum MISMATCH, refusing to run it" >&2
  echo "  expected ${SHA256}" >&2
  echo "  actual   ${GOT}" >&2
  rm -f "${DEST}.tmp"
  exit 1
fi
chmod +x "${DEST}.tmp"
mv "${DEST}.tmp" "${DEST}"
echo "install-mise: ${MISE_VERSION} (${ARCH}) sha256 OK -> ${DEST}"
