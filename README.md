# Marimo Desktop

A native macOS 26 app for [Marimo](https://marimo.io) notebooks: tabs, native New/Open/Save As, a live variable browser and a Git panel.

## Requirements
- macOS 26 (Tahoe), Apple Silicon or Intel
- Swift 6.2+ toolchain (Command Line Tools are enough)
- `uv` (recommended: `brew install uv`) or Python 3.9+. On first launch the app builds a private venv in `~/Library/Application Support/MarimoDesktop/venv` and installs Marimo there. This needs internet access once.

## Build and run
```bash
scripts/build_app.sh                 # builds build/MarimoDesktop.app (ad-hoc signed)
open build/MarimoDesktop.app
```
If macOS blocks the app: `xattr -dr com.apple.quarantine build/MarimoDesktop.app`.

## Test
```bash
scripts/test.sh                              # fast, offline unit tests
MARIMO_INTEGRATION=1 scripts/test.sh         # also runs real-Marimo integration tests
```
Build products go to `~/.cache/marimodesktop-build` (override with `MD_BUILD_DIR`).

## Packages and environments
Settings (⌘,) ▸ Environments lists installed packages with versions and lets you install or uninstall them. Create named environments, or link an existing venv/conda folder. Pick the environment per notebook from the toolbar; after package changes, notebooks offer **Restart to apply**.

## Shortcuts
⌘N new · ⌘O open · ⌘S save · ⇧⌘S save as · ⌘W close tab · ⇧⌘[ / ⇧⌘] switch tab · ⌥⌘I variables · ⌘↩ commit (in Git panel)

## Project docs
SPECIFICATION.md · WORKPLAN.md · DEVLOG.md · AGENTS.md · SKILLS.md
