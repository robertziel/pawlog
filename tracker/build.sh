#!/bin/sh
# Runs in oven/bun (see `make tracker`). Fails if the gzip budget is blown.
set -eu
cd "$(dirname "$0")"
bun build src/pawlog.ts --minify --format iife --target browser --outfile dist/pawlog.js >/dev/null
size=$(gzip -9c dist/pawlog.js | wc -c)
echo "dist/pawlog.js $(wc -c < dist/pawlog.js) B, $size B gzip (budget 4096)"
[ "$size" -lt 4096 ]
