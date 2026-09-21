#!/usr/bin/env bash
# Downloads the AMI audio listed in manifest.json into the cache and checks
# each file's SHA-256. Files already present and matching are left alone.
#
#   AURICLE_AMI_CACHE   cache directory (default: ~/Library/Caches/auricle-ami)
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cache=${AURICLE_AMI_CACHE:-$HOME/Library/Caches/auricle-ami}
mkdir -p "$cache"

python3 - "$here/manifest.json" <<'PY' | while read -r id sha url; do
import json, sys
m = json.load(open(sys.argv[1]))
for meeting in m["meetings"]:
    print(meeting["id"], meeting["sha256"], m["url_template"].format(id=meeting["id"]))
PY
    file=$cache/$id.Mix-Headset.wav
    if [ -f "$file" ] && [ "$(shasum -a 256 "$file" | cut -d' ' -f1)" = "$sha" ]; then
        echo "$id: cached" >&2
        continue
    fi
    echo "$id: downloading" >&2
    curl -fsSL -o "$file.part" "$url"
    mv "$file.part" "$file"
    [ "$(shasum -a 256 "$file" | cut -d' ' -f1)" = "$sha" ] || { echo "$id: checksum mismatch" >&2; exit 1; }
done
