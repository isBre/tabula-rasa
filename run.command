#!/bin/bash
# Avvia il gioco senza debugger: gli errori negli script dell'agente non bloccano il gioco.
cd "$(dirname "$0")"
GODOT="/Applications/Godot.app/Contents/MacOS/Godot"
if [ ! -x "$GODOT" ]; then GODOT="$(command -v godot)"; fi
"$GODOT" --path .
