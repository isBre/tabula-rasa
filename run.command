#!/bin/bash
# Starts the game without the debugger: errors in the agents' scripts don't freeze the game.
cd "$(dirname "$0")"
GODOT="/Applications/Godot.app/Contents/MacOS/Godot"
if [ ! -x "$GODOT" ]; then GODOT="$(command -v godot)"; fi
"$GODOT" --path .
