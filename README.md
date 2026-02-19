# Fantasy Map Editor

Godot 4 desktop editor for fantasy map authoring.

## Implemented core

- Land paint / erase with brush strokes.
- Coastline auto smoothing (Chaikin-based, 0..100 with presets 20/40/70).
- Brush types: `circle`, `texture`, `noise`.
- Tile erase (`64x64`) with single tile and drag multi-tile modes.
- Mountains and rivers as editable terrain strokes.
- Country and region polygon drawing (region clamp to selected country).
- Undo / redo snapshots across terrain + political layers.
- Project save/load with extended terrain schema.

## Controls

- `LMB`: edit with active tool.
- `MMB drag`: pan camera.
- `Mouse wheel`: zoom in/out.
- `Enter`: finalize country/region polygon draft.
- `Esc`: cancel polygon draft.
- `Backspace`: remove last polygon vertex.
- `Ctrl+Z` / `Ctrl+Y`: undo / redo.

Project path is saved to `user://fantasy_map_project.json`.
