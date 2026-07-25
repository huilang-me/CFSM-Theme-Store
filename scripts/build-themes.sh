#!/bin/bash

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
PROJECT_ROOT=$(dirname "$SCRIPT_DIR")

THEMES_FILE="$PROJECT_ROOT/themes.json"
DIST_DIR="$PROJECT_ROOT/dist"
TMP_DIR=$(mktemp -d)

rm -rf "$DIST_DIR"

mkdir -p "$DIST_DIR"

num_themes=$(jq -r '.themes | length' "$THEMES_FILE" 2>/dev/null || echo 0)

for ((i=0; i<num_themes; i++)); do
  url=$(jq -r ".themes[$i].url" "$THEMES_FILE" 2>/dev/null || echo "")
  
  if [[ "$url" != "null" && -n "$url" ]]; then
    repo_path=$(echo "$url" | sed 's|https://github.com/||' | sed 's|/$||')
    
    if [[ -n "$repo_path" ]]; then
      owner=$(echo "$repo_path" | cut -d'/' -f1)
      repo=$(echo "$repo_path" | cut -d'/' -f2)
      
      theme_base_dir="$DIST_DIR/$owner/$repo"
      mkdir -p "$theme_base_dir"
      
      versions=$(jq -r ".themes[$i].versions | keys[]?" "$THEMES_FILE" 2>/dev/null || echo "")
      
      clone_dir="$TMP_DIR/$owner-$repo"
      rm -rf "$clone_dir"
      cloned=false
      
      for version in $versions; do
        commitid=$(jq -r ".themes[$i].versions[\"$version\"].commitid" "$THEMES_FILE" 2>/dev/null || echo "")
        
        if [[ "$commitid" == "null" || -z "$commitid" ]]; then
          echo "Warning: No commitid for $repo_path version $version, skipping"
          continue
        fi
        
        theme_dist_dir="$theme_base_dir/$version"
        
        if [[ -d "$theme_dist_dir" ]]; then
          echo "=== Skipping $repo_path version $version (already exists) ==="
          continue
        fi
        
        echo "=== Building $repo_path version $version (commit: $commitid) ==="
        
        mkdir -p "$theme_dist_dir"
        
        if [[ $cloned == false ]]; then
          if ! git clone "$url" "$clone_dir"; then
            echo "Error: Failed to clone $url"
            rm -rf "$theme_dist_dir"
            continue
          fi
          cloned=true
        fi
        
        cd "$clone_dir"
        
        if ! git checkout "$commitid"; then
          echo "Error: Failed to checkout commit $commitid for $repo_path"
          cd "$PROJECT_ROOT"
          rm -rf "$theme_dist_dir"
          continue
        fi
        
        if npm install && npm run build; then
          if [[ -d "dist" ]]; then
            cp -r dist/* "$theme_dist_dir/"
            echo "Successfully built and copied to $theme_dist_dir"
          elif [[ -d "build" ]]; then
            cp -r build/* "$theme_dist_dir/"
            echo "Successfully built and copied to $theme_dist_dir (using build directory)"
          else
            echo "Warning: No dist or build directory found for $repo_path"
          fi
        else
          echo "Error: Build failed for $repo_path version $version"
          rm -rf "$theme_dist_dir"
        fi
        
        cd "$PROJECT_ROOT"
      done
    fi
  fi
done

echo "=== Cleaning up removed versions ==="

for ((i=0; i<num_themes; i++)); do
  url=$(jq -r ".themes[$i].url" "$THEMES_FILE" 2>/dev/null || echo "")
  
  if [[ "$url" != "null" && -n "$url" ]]; then
    repo_path=$(echo "$url" | sed 's|https://github.com/||' | sed 's|/$||')
    
    if [[ -n "$repo_path" ]]; then
      owner=$(echo "$repo_path" | cut -d'/' -f1)
      repo=$(echo "$repo_path" | cut -d'/' -f2)
      
      theme_base_dir="$DIST_DIR/$owner/$repo"
      
      if [[ -d "$theme_base_dir" ]]; then
        valid_versions=$(jq -r ".themes[$i].versions | keys[]?" "$THEMES_FILE" 2>/dev/null || echo "")
        
        shopt -s nullglob
        existing_versions=("$theme_base_dir"/*/)
        shopt -u nullglob
        
        for existing_version_dir in "${existing_versions[@]}"; do
          existing_version=$(basename "$existing_version_dir")
          
          if ! echo "$valid_versions" | grep -q "^$existing_version$"; then
            echo "Deleting removed version: $theme_base_dir/$existing_version"
            rm -rf "$theme_base_dir/$existing_version"
          fi
        done
      fi
    fi
  fi
done

rm -rf "$TMP_DIR"
echo "=== Build process completed ==="
