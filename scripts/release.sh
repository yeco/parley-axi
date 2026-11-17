#!/usr/bin/env bash
# Cut a release: pick the next version by semver from the commits since the last release, bump
# package.json, commit "chore(release): vX.Y.Z" and tag vX.Y.Z. It never pushes; pushing the tag
# runs .github/workflows/publish.yml. Usage: scripts/release.sh [--dry-run]
set -euo pipefail
dry=0
case "${1:-}" in
  --dry-run) dry=1 ;;
  '') ;;
  *) echo "usage: scripts/release.sh [--dry-run]" >&2; exit 2 ;;
esac

# Last release: the latest v* tag; with none, the commit that last changed package.json "version".
base=$(git tag --list 'v*' --sort=-v:refname | head -n1)
if [ -n "$base" ]; then from="$base"; else from=$(git log -1 --format=%H -G'"version"' -- package.json); fi
[ -n "$from" ] || { echo "no previous release found (no v* tag, no package.json version commit)" >&2; exit 1; }

current=$(sed -n 's/^  "version": "\([0-9]*\.[0-9]*\.[0-9]*\)".*/\1/p' package.json | head -n1)
[ -n "$current" ] || { echo "cannot read x.y.z version from package.json" >&2; exit 1; }
IFS=. read -r major minor patch <<<"$current"

level="none" reason=""
while IFS= read -r -d $'\x1e' record; do
  record=${record#$'\n'}
  [ -n "$record" ] || continue
  subject=${record%%$'\x1f'*} body=${record#*$'\x1f'}
  if [[ $subject =~ ^[a-z]+(\(.+\))?!: ]] || grep -qE '^BREAKING[ -]CHANGE:' <<<"$body"; then
    c=major
  elif [[ $subject =~ ^feat(\(.+\))?: ]]; then c=minor
  else c="patch"; fi
  # 0.x: a breaking change bumps minor
  [ "$c" = major ] && [ "$major" = 0 ] && c=minor
  case "$c:$level" in
    major:*) level=major; reason=$subject ;;
    minor:none|minor:patch) level=minor; reason=$subject ;;
    patch:none) level="patch"; reason=$subject ;;
  esac
done < <(git log --format='%s%x1f%b%x1e' "$from..HEAD")

if [ "$level" = none ]; then echo "no commits since $from; nothing to release" >&2; exit 1; fi
case $level in
  major) next="$((major + 1)).0.0" ;;
  minor) next="$major.$((minor + 1)).0" ;;
  patch) next="$major.$minor.$((patch + 1))" ;;
esac
echo "v$next ($level from $current; since $from; driven by: $reason)"
[ "$dry" = 1 ] && exit 0

[ -z "$(git status --porcelain)" ] || { echo "working tree is not clean" >&2; exit 1; }
sed -i "0,/^  \"version\": \"$current\"/s//  \"version\": \"$next\"/" package.json
git commit -q -am "chore(release): v$next"
git tag "v$next"
echo "tagged v$next; publish with: git push origin v$next"
