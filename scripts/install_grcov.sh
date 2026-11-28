#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: bash $0 <install-directory>" >&2
    exit 1
fi

destination=$1
download_dir=$(mktemp -d)
trap 'rm -rf -- "$download_dir"' EXIT

release_url="https://github.com/mozilla/grcov/releases/latest"
archive="grcov-$(uname -m)-unknown-linux-musl.tar.bz2"
wget --quiet -O "$download_dir/checksums.sha256" "$release_url/download/checksums.sha256"
wget --quiet -O "$download_dir/$archive" "$release_url/download/$archive"
checksum=$(awk -v archive="$archive" '$2 == archive || $2 == "*" archive { print $1 }' "$download_dir/checksums.sha256")
printf '%s  %s\n' "$checksum" "$download_dir/$archive" | sha256sum -c -
tar -xjf "$download_dir/$archive" -C "$download_dir" grcov
rustup component add llvm-tools-preview
install -D -m 755 "$download_dir/grcov" "$destination/grcov"
