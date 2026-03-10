#!/bin/sh

set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"

hash_file="nix/default.nix"
lock_file="flake.lock"
build_log=$(mktemp)
hash_backup=$(mktemp)
lock_backup=$(mktemp)

cleanup() {
  status=$?

  if [ "$status" -ne 0 ]; then
    if [ -f "$hash_backup" ]; then
      cp "$hash_backup" "$hash_file"
    fi

    if [ -f "$lock_backup" ]; then
      cp "$lock_backup" "$lock_file"
    fi
  fi

  rm -f "$build_log" "$hash_backup" "$lock_backup"
}

trap cleanup EXIT HUP INT TERM

extract_spacebot_rev() {
  awk '
    /"spacebot-src": \{/ { in_block=1 }
    in_block && /"rev": "/ {
      line = $0
      sub(/^.*"rev": "/, "", line)
      sub(/".*$/, "", line)
      print line
      exit
    }
    in_block && /^    }/ { in_block=0 }
  ' "$lock_file"
}

rewrite_hash_line() {
  replacement=$1
  tmp_file=$(mktemp)
  sed "s|frontendNodeModulesHash = .*;|frontendNodeModulesHash = ${replacement};|" "$hash_file" > "$tmp_file"
  mv "$tmp_file" "$hash_file"
}

if ! grep -q "frontendNodeModulesHash = " "$hash_file"; then
  printf '%s\n' "Could not find frontendNodeModulesHash in $hash_file" >&2
  exit 1
fi

cp "$hash_file" "$hash_backup"
cp "$lock_file" "$lock_backup"

old_rev=$(extract_spacebot_rev)

if [ -z "$old_rev" ]; then
  printf '%s\n' "Could not extract current spacebot-src revision from $lock_file" >&2
  exit 1
fi

printf '%s\n' "Updating spacebot-src in $lock_file"
nix flake update spacebot-src

new_rev=$(extract_spacebot_rev)

if [ -z "$new_rev" ]; then
  printf '%s\n' "Could not extract updated spacebot-src revision from $lock_file" >&2
  exit 1
fi

if [ "$old_rev" = "$new_rev" ]; then
  printf '%s\n' "spacebot-src already at $new_rev; nothing to do"
  exit 0
fi

printf '%s\n' "Refreshing frontendNodeModulesHash"
rewrite_hash_line "lib.fakeHash"

if nix build .#frontend --no-link >"$build_log" 2>&1; then
  printf '%s\n' "Expected a hash mismatch while computing frontendNodeModulesHash" >&2
  cat "$build_log" >&2
  exit 1
fi

actual_hash=$(sed -n 's/^[[:space:]]*got:[[:space:]]*\(sha256-[A-Za-z0-9+/=]*\)[[:space:]]*$/\1/p' "$build_log" | tail -n 1)

if [ -z "$actual_hash" ]; then
  printf '%s\n' "Could not extract frontendNodeModulesHash from nix build output" >&2
  cat "$build_log" >&2
  exit 1
fi

rewrite_hash_line "\"$actual_hash\""

printf '%s\n' "Updated $lock_file and $hash_file"
