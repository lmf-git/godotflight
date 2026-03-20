#!/usr/bin/env bash
# Build the Rust GDExtension (voxel terrain) before opening Godot.
# Must be run once before the first launch, and after any changes to rust/src/.
#
# Usage:
#   ./build.sh          — debug build (fast, used by default .gdextension)
#   ./build.sh release  — release build (optimised, use for export)

set -e
cd "$(dirname "$0")/rust"

if [ "$1" = "release" ]; then
    echo "Building voxel_terrain (release)..."
    cargo build --release
    echo "Done: rust/target/release/libvoxel_terrain.dylib"
else
    echo "Building voxel_terrain (debug)..."
    cargo build -j 2
    echo "Done: rust/target/debug/libvoxel_terrain.dylib"
fi

echo ""
echo "You can now open the Godot project."
