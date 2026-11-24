#!/bin/sh
# Rewrites Sources/HarborKit/Resources/en.lproj/Localizable.strings from the sources: every sentence the app and
# HarborKit look up (String(localized:), SwiftUI's Text, Button and the like), as the compiler itself lists them.
# English is the key, so each line reads "sentence" = "sentence"; a translation is a copy of the file in its own
# <language>.lproj with the right-hand sides changed. Sentences with a form per number are in
# Localizable.stringsdict beside it, written by hand. Run after adding or changing a sentence.
set -eu
cd "$(dirname "$0")/.."
if [ -z "${DEVELOPER_DIR:-}" ]; then
  export DEVELOPER_DIR="$(ls -d /Applications/Xcode*.app | sort -V | tail -1)/Contents/Developer"
fi
OUT=Sources/HarborKit/Resources/en.lproj/Localizable.strings
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/data"
# A build of its own: the compiler only lists a file's sentences when it compiles that file.
swift build --build-system native --scratch-path "$work/build" --product Harbor \
  -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$work/data" > "$work/log" 2>&1 \
  || { grep -v "has been deprecated" "$work/log" >&2; echo "update-strings: build failed" >&2; exit 1; }
python3 -I - "$work/data" "$OUT" <<'PY'
import glob, json, sys
keys = set()
for path in glob.glob(sys.argv[1] + "/*.stringsdata"):
    for entries in json.load(open(path)).get("tables", {}).values():
        keys.update(e["key"] for e in entries if e["key"])
esc = lambda s: s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
with open(sys.argv[2], "w", encoding="utf-8") as out:
    out.write("/* Every sentence Harbor shows, written by scripts/update-strings.sh. English is the key. */\n")
    for key in sorted(keys, key=str.lower):
        out.write('"%s" = "%s";\n' % (esc(key), esc(key)))
print("update-strings: %d sentences in %s" % (len(keys), sys.argv[2]))
PY
