# SKILLS.md — reusable procedures for this project

Step-by-step playbooks. Follow the matching one instead of improvising. All rules in AGENTS.md still apply.

## Skill 1 — Run a development stage
1. Read the stage in WORKPLAN.md. Mark it ◐ and add a "Stage N started" entry to DEVLOG.md.
2. Write or extend tests first for any core logic.
3. Implement. Keep the diff scoped to the stage.
4. `swift build` and `swift test`; fix all warnings.
5. Mark the stage ☑ in WORKPLAN.md, and add a DEVLOG "Stage N finished" entry (what was built, decisions, issues).
6. `git add -A && git commit` as `claude-sonnet`.

## Skill 2 — App development (SwiftUI + AppKit on macOS 26)
- Model → View: create the `@Observable` model, then thin views. Use `@Bindable` for bindings.
- Wrap AppKit/WebKit with `NSViewRepresentable`. Keep one coordinator per representable and never retain the model strongly in a closure that outlives the view.
- Menu commands: use `.commands { CommandGroup … }` and `FocusedValue` to reach the active tab. Replace `.newItem` and `.saveItem` groups for New/Open/Save.
- Dialogs: `NSOpenPanel`/`NSSavePanel` via `begin`/`runModal` on the main actor. Set `allowedContentTypes = [.pythonScript]`.
- Glass: group related glass controls in a `GlassEffectContainer`. Never stack glass on glass or put it on content areas.
- Wait for Marimo readiness by polling `GET /health` until 200, with a timeout and visible progress.

## Skill 3 — Managing the Python/Marimo environment
- Prefer `uv venv` and `uv pip install --python <venv>/bin/python marimo`. Fall back to `python3 -m venv` plus `pip`.
- Always call the venv's absolute `python`/`marimo` paths. Never rely on PATH or activation scripts.
- Probe the version with `python -c "import marimo;print(marimo.__version__)"`.
- Stream stdout/stderr to the UI log. A non-zero exit becomes a typed error carrying the last 20 log lines.

## Skill 4 — Testing
- Unit: `swift test` (fast, offline). Pure parsers with fixture strings. Fake `ProcessRunner` for command assertions.
- Integration: `MARIMO_INTEGRATION=1 swift test` launches real marimo in a temp venv.
- Git: create a temp dir, `git init`, and drive `GitClient` against it. Always clean up.
- App smoke test: `scripts/build_app.sh`, `open build/MarimoDesktop.app`, check `pgrep -fl marimo` while it runs, quit, and confirm that none remain.
- Capture a screenshot with `screencapture -x` when verifying visuals, and inspect it.

## Skill 5 — Debugging
- Server won't start: run the exact command from the tab's diagnostics log in Terminal. Check the port and the venv path.
- Blank web view: check the `WKNavigationDelegate` error callbacks and open the Web Inspector (enable `isInspectable`).
- Variables empty: inspect the kiosk WebSocket frames. Dump the raw JSON to a fixture and compare with the parser.
- Orphaned processes: inspect `~/Library/Application Support/MarimoDesktop/pids.json`.

## Skill 6 — User engagement and feedback
- Surface state, not silence: every long operation shows progress, and every failure shows a plain-language message with a next action (Retry / Open Log / Choose Python).
- First-run experience: the welcome and setup screens explain what is happening ("Creating a private Python environment — one time only").
- Provide Help menu links (Marimo docs, report an issue), a diagnostics copy button, and a "Copy debug info" action for bug reports.
- Keep an in-repo "Known issues" section in DEVLOG.md. Tell the user plainly what is untested.
- When handing off for user testing, give: the build command, the launch command, a 5-step smoke checklist, and known limitations.

## Skill 7 — Release build and handoff
1. `swift build -c release`, then `scripts/build_app.sh` (assemble, `codesign --force --deep --sign -`).
2. Verify with `codesign --verify --deep --strict build/MarimoDesktop.app`, then launch it.
3. If Gatekeeper blocks it: `xattr -dr com.apple.quarantine build/MarimoDesktop.app`.
4. Give the user: `open "<abs path>/build/MarimoDesktop.app"`.
