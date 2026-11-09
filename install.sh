#!/usr/bin/env bash
# Installs this local port only; never downloads the upstream shell.
set -euo pipefail
for arg in "$@"; do
    if [[ "$arg" == --python-bridge ]]; then
        echo 'The Python installer is retired; run install.sh without --python-bridge.' >&2
        exit 2
    fi
done
source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/macshell-installer.XXXXXXXX")
trap 'rm -rf -- "$build_dir"' EXIT
cargo build --release --locked --offline --manifest-path "$source_dir/native/installer/Cargo.toml" --target-dir "$build_dir" >&2
"$build_dir/release/macshell-installer" cli "$source_dir" "$@"
