#!/bin/sh
set -eu

repoDir="$(cd "$(dirname "$0")/.." && pwd)"
previewDir="$(mktemp -d "${TMPDIR:-/tmp}/routerchat-swirl-preview.XXXXXX")"
trap 'rm -rf "$previewDir"' EXIT INT TERM HUP

sed '$d' "$repoDir/install.sh" >"$previewDir/install-functions.sh"
. "$previewDir/install-functions.sh"

printHeader
