#!/usr/bin/env bash
set -euo pipefail
source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
revision=2e9b2b0228432d5e402a9c90a031b419960d0bd1
work_dir=${MACSHELL_OWLY_BUILD_DIR:-$source_dir/build/owly}
mkdir -p "$work_dir"
if [[ ! -d "$work_dir/source/.git" ]]; then
    git clone https://github.com/t4t5/owly.git "$work_dir/source"
    git -C "$work_dir/source" checkout --detach "$revision"
fi
[[ $(git -C "$work_dir/source" rev-parse HEAD) == "$revision" ]] || { printf '%s\n' 'Owly checkout has a different revision; use a fresh build directory.' >&2; exit 1; }
if git -C "$work_dir/source" apply --check "$source_dir/native/owly/macshell-cli.patch" 2>/dev/null; then
    git -C "$work_dir/source" apply "$source_dir/native/owly/macshell-cli.patch"
else
    git -C "$work_dir/source" apply --reverse --check "$source_dir/native/owly/macshell-cli.patch"
fi
cp "$source_dir/native/owly/macshell.rs" "$work_dir/source/crates/owly-cli/src/macshell.rs"
export CARGO_HOME=${CARGO_HOME:-$work_dir/cargo-home}
cd "$work_dir/source"
cargo build --release --locked -p owlyd -p owly-cli
target/release/owly macshell capabilities
printf 'Built backend: %s\n' "$work_dir/source/target/release/owly"
printf '%s\n' 'No system service was installed and no Wi-Fi radio was acquired.'
