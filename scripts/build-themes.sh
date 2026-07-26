#!/bin/bash

set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
PROJECT_ROOT=$(dirname "$SCRIPT_DIR")

THEMES_FILE=${THEMES_FILE:-"$PROJECT_ROOT/themes.json"}
DIST_DIR=${DIST_DIR:-"$PROJECT_ROOT/dist"}
PREVIOUS_THEMES_FILE=${PREVIOUS_THEMES_FILE:-}

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

normalize_theme_entries() {
  local file=$1

  jq -r '
    def repo_path:
      sub("^https://github.com/"; "")
      | sub("/$"; "");

    if (.themes | type) != "array" then
      error(".themes must be an array")
    else
      empty
    end,
    .themes[]
    | if (.url | type) != "string" then
        error("theme url must be a string")
      else
        .
      end
    | .url as $url
    | ($url | repo_path) as $repo_path
    | if ($repo_path | test("^[^/]+/[^/]+$") | not) then
        error("theme url must be a GitHub repository URL: \($url)")
      else
        .
      end
    | if (.versions | type) != "array" then
        error("theme versions must be an array for \($url)")
      else
        .
      end
    | .versions[]? as $version
    | if (($version.version | type) != "string") or (($version.version | length) == 0) then
        error("theme version must be a non-empty string for \($url)")
      else
        .
      end
    | if (($version.commitid | type) != "string") or (($version.commitid | test("^[0-9a-fA-F]{7,40}$") | not)) then
        error("theme commitid must be a git commit hash for \($url) \($version.version)")
      else
        .
      end
    | [$repo_path, $url, $version.version, ($version.commitid | ascii_downcase)]
    | @tsv
  ' "$file"
}

normalize_dist_metadata() {
  local file=$1

  jq -r '
    .builds[]?
    | select((.path | type) == "string" and (.url | type) == "string" and (.version | type) == "string" and (.commitid | type) == "string")
    | [.path, .url, .version, (.commitid | ascii_downcase)]
    | @tsv
  ' "$file"
}

normalize_dist_tree() {
  local dist_dir=$1
  local owner_dir repo_dir version_dir owner repo version

  shopt -s nullglob
  for owner_dir in "$dist_dir"/*; do
    [[ -d "$owner_dir" ]] || continue
    owner=$(basename "$owner_dir")

    for repo_dir in "$owner_dir"/*; do
      [[ -d "$repo_dir" ]] || continue
      repo=$(basename "$repo_dir")

      for version_dir in "$repo_dir"/*; do
        [[ -d "$version_dir" ]] || continue
        version=$(basename "$version_dir")
        printf '%s/%s\t__dist_tree__\t%s\t__unknown__\n' "$owner" "$repo" "$version"
      done
    done
  done
  shopt -u nullglob
}

write_entries() {
  local source_file=$1
  local output_file=$2
  local duplicates

  normalize_theme_entries "$source_file" | sort -u >"$output_file"

  duplicates=$(cut -f1,3 "$output_file" | sort | uniq -d)
  if [[ -n "$duplicates" ]]; then
    echo "Error: duplicate theme version entries found:" >&2
    echo "$duplicates" >&2
    exit 1
  fi
}

write_current_metadata() {
  local current_entries=$1
  local metadata_entries=$TMP_DIR/metadata.tsv
  local metadata_file=$DIST_DIR/.theme-builds.json
  local generated_at

  : >"$metadata_entries"

  while IFS=$'\t' read -r repo_path url version commitid; do
    [[ -n "$repo_path" ]] || continue
    if [[ -d "$DIST_DIR/$repo_path/$version" ]]; then
      printf '%s\t%s\t%s\t%s\n' "$repo_path" "$url" "$version" "$commitid" >>"$metadata_entries"
    fi
  done <"$current_entries"

  generated_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  jq -Rn --arg generatedAt "$generated_at" '
    [inputs | select(length > 0) | split("\t") | {
      path: .[0],
      url: .[1],
      version: .[2],
      commitid: .[3]
    }] as $builds
    | {
      schema: 1,
      generatedAt: $generatedAt,
      builds: $builds
    }
  ' <"$metadata_entries" >"$metadata_file"
}

previous_commit_for() {
  local previous_entries=$1
  local repo_path=$2
  local version=$3

  awk -F '\t' -v repo_path="$repo_path" -v version="$version" '
    $1 == repo_path && $3 == version {
      print $4
      exit
    }
  ' "$previous_entries"
}

has_current_key() {
  local current_keys=$1
  local repo_path=$2
  local version=$3

  grep -Fqx "$repo_path	$version" "$current_keys"
}

install_dependencies() {
  if [[ -f package-lock.json || -f npm-shrinkwrap.json ]]; then
    npm ci
  else
    npm install
  fi
}

build_theme_version() {
  local repo_path=$1
  local url=$2
  local version=$3
  local commitid=$4
  local clone_dir=$5
  local theme_dist_dir=$DIST_DIR/$repo_path/$version
  local output_dir

  echo "=== Building $repo_path $version (commit: $commitid) ==="

  if [[ ! -d "$clone_dir/.git" ]]; then
    rm -rf "$clone_dir"
    git clone "$url" "$clone_dir"
  fi

  (
    cd "$clone_dir"
    git fetch --all --tags --prune
    git checkout --force "$commitid"

    install_dependencies
    npm run build

    if [[ -d dist ]]; then
      output_dir=dist
    elif [[ -d build ]]; then
      output_dir=build
    else
      echo "Error: No dist or build directory found for $repo_path $version" >&2
      exit 1
    fi

    rm -rf "$theme_dist_dir"
    mkdir -p "$theme_dist_dir"
    cp -a "$output_dir"/. "$theme_dist_dir"/
  )

  echo "Successfully built and copied to $theme_dist_dir"
}

if [[ "${1:-}" == "--list" ]]; then
  normalize_theme_entries "${2:-$THEMES_FILE}" | sort -u
  exit 0
fi

mkdir -p "$DIST_DIR"

current_entries=$TMP_DIR/current.tsv
previous_entries=$TMP_DIR/previous.tsv
current_keys=$TMP_DIR/current.keys

write_entries "$THEMES_FILE" "$current_entries"
cut -f1,3 "$current_entries" | sort -u >"$current_keys"

: >"$previous_entries"
if [[ -n "$PREVIOUS_THEMES_FILE" && -f "$PREVIOUS_THEMES_FILE" ]]; then
  write_entries "$PREVIOUS_THEMES_FILE" "$previous_entries"
elif [[ -f "$DIST_DIR/.theme-builds.json" ]]; then
  normalize_dist_metadata "$DIST_DIR/.theme-builds.json" | sort -u >"$previous_entries"
else
  normalize_dist_tree "$DIST_DIR" | sort -u >"$previous_entries"
fi

echo "=== Removing deleted theme versions ==="
while IFS=$'\t' read -r repo_path _url version _commitid; do
  [[ -n "$repo_path" ]] || continue
  if ! has_current_key "$current_keys" "$repo_path" "$version"; then
    echo "Deleting removed version: $DIST_DIR/$repo_path/$version"
    rm -rf "$DIST_DIR/$repo_path/$version"
  fi
done <"$previous_entries"

echo "=== Building changed theme versions ==="
built_count=0
skipped_count=0

while IFS=$'\t' read -r repo_path url version commitid; do
  [[ -n "$repo_path" ]] || continue

  theme_dist_dir=$DIST_DIR/$repo_path/$version
  previous_commit=$(previous_commit_for "$previous_entries" "$repo_path" "$version")

  if [[ -d "$theme_dist_dir" && ( -z "$previous_commit" || "$previous_commit" == "__unknown__" || "$previous_commit" == "$commitid" ) ]]; then
    echo "=== Skipping $repo_path $version (already built) ==="
    skipped_count=$((skipped_count + 1))
    continue
  fi

  owner=${repo_path%%/*}
  repo=${repo_path#*/}
  clone_dir=$TMP_DIR/$owner-$repo

  build_theme_version "$repo_path" "$url" "$version" "$commitid" "$clone_dir"
  built_count=$((built_count + 1))
done <"$current_entries"

find "$DIST_DIR" -mindepth 1 \( -name .git -o -path "$DIST_DIR/.git/*" \) -prune -o -type d -empty -delete
write_current_metadata "$current_entries"

echo "=== Build process completed: $built_count built, $skipped_count skipped ==="
