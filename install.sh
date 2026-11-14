#!/bin/sh
# ShieldScan on-prem agent installer.
#
#   curl -fsSL https://raw.githubusercontent.com/mahmoudothman-cloud/shieldscan-agent/main/install.sh | sh
#   curl -fsSL .../install.sh | sh -s -- v0.1.0        # a specific version
#
# Downloads the release archive for this OS/arch, verifies it against the
# release's checksums.txt (and, when cosign is installed, verifies the
# Sigstore signature on checksums.txt), and installs the binary to
# /usr/local/bin (or $SHIELDSCAN_AGENT_BIN_DIR). Nothing else is written.
set -eu

REPO="mahmoudothman-cloud/shieldscan-agent"
BIN_DIR="${SHIELDSCAN_AGENT_BIN_DIR:-/usr/local/bin}"
VERSION="${1:-}"

say() { printf '%s\n' "$*" >&2; }
die() { say "install: $*"; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "need $1"; }
need curl; need tar; need uname

os=$(uname -s | tr '[:upper:]' '[:lower:]')
case "$os" in linux|darwin) ;; *) die "unsupported OS: $os (linux and darwin are built)";; esac
arch=$(uname -m)
case "$arch" in
  x86_64|amd64) arch=amd64 ;;
  aarch64|arm64) arch=arm64 ;;
  *) die "unsupported architecture: $arch" ;;
esac

if [ -z "$VERSION" ]; then
  VERSION=$(curl -fsSL -H 'Accept: application/vnd.github+json' "https://api.github.com/repos/$REPO/releases/latest" \
    | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n1)
  [ -n "$VERSION" ] || die "could not determine the latest release"
fi
case "$VERSION" in v*) ;; *) VERSION="v$VERSION";; esac
bare="${VERSION#v}"

base="https://github.com/$REPO/releases/download/$VERSION"
archive="shieldscan-agent_${bare}_${os}_${arch}.tar.gz"

tmp=$(mktemp -d 2>/dev/null || mktemp -d -t ssagent)
trap 'rm -rf "$tmp"' EXIT
cd "$tmp"

say "downloading $archive ($VERSION)"
curl -fsSL -o "$archive" "$base/$archive"
curl -fsSL -o checksums.txt "$base/checksums.txt"

# Signature on the checksum file (optional, needs cosign).
if command -v cosign >/dev/null 2>&1; then
  curl -fsSL -o checksums.txt.pem "$base/checksums.txt.pem"
  curl -fsSL -o checksums.txt.sig "$base/checksums.txt.sig"
  cosign verify-blob --certificate checksums.txt.pem --signature checksums.txt.sig \
    --certificate-identity-regexp 'github.com/mahmoudothman-cloud/shieldscan-engine' \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com checksums.txt >/dev/null \
    && say "checksums.txt signature verified (Sigstore)" \
    || die "checksums.txt signature did NOT verify"
else
  say "cosign not installed: skipping signature verification (sha256 still checked)"
fi

# Checksum of the archive.
expected=$(grep " $archive\$" checksums.txt | cut -d' ' -f1)
[ -n "$expected" ] || die "$archive not listed in checksums.txt"
if command -v sha256sum >/dev/null 2>&1; then actual=$(sha256sum "$archive" | cut -d' ' -f1)
else actual=$(shasum -a 256 "$archive" | cut -d' ' -f1); fi
[ "$expected" = "$actual" ] || die "checksum mismatch for $archive"
say "sha256 ok"

tar -xzf "$archive"
[ -x shieldscan-agent ] || die "archive did not contain the binary"

if [ -w "$BIN_DIR" ]; then install -m 0755 shieldscan-agent "$BIN_DIR/shieldscan-agent"
else say "installing to $BIN_DIR with sudo"; sudo install -m 0755 shieldscan-agent "$BIN_DIR/shieldscan-agent"; fi

say ""
say "installed: $("$BIN_DIR/shieldscan-agent" version)"
say "next:"
say "  shieldscan-agent doctor                                  # which scanners are found"
say "  shieldscan-agent enroll --api https://<your-shieldscan> --token <token>   # token from Settings → Agents"
say "  shieldscan-agent run                                     # or install shieldscan-agent.service from the archive"
