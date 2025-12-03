#!/bin/bash

# Package each binary in burrito_out into separate zip files with version

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BURRITO_OUT="$PROJECT_DIR/burrito_out"

# Extract version from mix.exs
VERSION=$(grep -E 'version: "' "$PROJECT_DIR/mix.exs" | head -1 | sed 's/.*version: "\([^"]*\)".*/\1/')

if [ -z "$VERSION" ]; then
    echo "Error: Could not extract version from mix.exs"
    exit 1
fi

echo "Packaging releases version $VERSION..."

# Check if burrito_out exists
if [ ! -d "$BURRITO_OUT" ]; then
    echo "Error: burrito_out directory not found at $BURRITO_OUT"
    exit 1
fi

# Package each binary
cd "$BURRITO_OUT"
for binary in *; do
    if [ -f "$binary" ] && [ -x "$binary" ]; then
        zip_name="${binary}_v${VERSION}.zip"
        echo "Creating $zip_name..."
        zip -j "$zip_name" "$binary"
        echo "  -> $(du -h "$zip_name" | cut -f1)"
    fi
done

echo ""
echo "Done! Packages created in $BURRITO_OUT:"
ls -la "$BURRITO_OUT"/*.zip 2>/dev/null || echo "No zip files found"
