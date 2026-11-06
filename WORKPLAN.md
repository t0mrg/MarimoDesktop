# Work Plan

Each stage ends with: build green, tests green, DEVLOG entry, git commit as `claude-sonnet`.
Status: ☐ todo · ◐ in progress · ☑ done

| # | Stage | Status |
|---|---|---|
| 0 | Documentation and repository | ☑ |
| 1 | Package skeleton, app shell, build script | ☑ |
| 2 | Python environment and Marimo server manager | ☑ |
| 3 | Tabs, web view, New / Open / Save As | ☑ |
| 4 | Variable browser (kiosk mirror) | ☑ |
| 5 | Git plugin | ☑ |
| 6 | Polish, persistence, lifecycle hardening | ☑ |
| 7 | End-to-end verification, release build, handoff | ☑ |
| 8 | Environment model: registry and PythonEnvironment refactor (v0.2) | ☑ |
| 9 | PackageManager: list / install / uninstall (v0.2) | ☑ |
| 10 | Per-notebook environments: launch, picker, restart banner (v0.2) | ☑ |
| 11 | Packages and Environments UI, faint placeholders (v0.2) | ☑ |
| 12 | Verification, rebuild, handoff (v0.2) | ☑ |

## Stage 0 — Documentation and repository
- SPECIFICATION.md, WORKPLAN.md, AGENTS.md, SKILLS.md, DEVLOG.md, .gitignore.
- `git init`, local identity `claude-sonnet`, first commit.
- **Done when:** the repo has a clean first commit.

## Stage 1 — Skeleton
- Package.swift (library `MarimoCore`, executable `MarimoDesktop`, test target), macOS 26 platform.
- App entry point, an empty NavigationSplitView with placeholder panes, Info.plist and `scripts/build_app.sh` (bundle, plist, ad-hoc codesign).
- **Done when:** `swift build` passes and `build_app.sh` yields a launching `.app`.

## Stage 2 — Environment and servers
- PythonEnvironment (detect uv/python, create venv, install marimo, version probe), streaming progress.
- PortAllocator, MarimoServer (spawn, readiness poll, terminate, PID file, log capture).
- Setup screen driven by AppModel.
- **Tests:** port allocation, readiness parsing, command construction, PID reaping. **Integration:** real marimo launch.
- **Done when:** a first-launch run installs marimo and a server answers on its port.

## Stage 3 — Tabs and files
- NotebookSession, WKWebView wrapper (origin-locked, external links to browser), tab bar with dirty/status, and a restore list.
- New (template), Open (NSOpenPanel, recents, drag-drop, document type), Save (via Marimo API), Save As (NSSavePanel + move), close-with-unsaved prompt.
- Menu commands and shortcuts.
- **Tests:** template, recents, tab model, save-as path logic.
- **Done when:** three notebooks open side by side and New, Open and Save As work.

## Stage 4 — Variable browser
- Probe the real kiosk protocol and pin the message schemas in tests (fixtures).
- VariableMirror (URLSessionWebSocketTask), the Variable model, the inspector view with search and copy.
- **Done when:** running a cell shows its variables in the inspector.

## Stage 5 — Git plugin
- GitClient (status --porcelain=v2, diff, add/restore, commit, log, branch, pull/push, init) plus parsers.
- Sidebar UI: status groups, diff sheet, commit box, history, branch menu.
- **Tests:** parser fixtures plus a temp-repo integration test.
- **Done when:** the full change → commit loop works in a temp repo from the UI.

## Stage 6 — Polish and hardening
- Liquid Glass pass, welcome screen, settings (update marimo, rebuild env, install packages), diagnostics log view, error alerts, app icon.
- Orphan-process guarantees. Accessibility labels.
- **Done when:** the spec's FR list is fully covered.

## Stage 7 — Verification and handoff
- Run the acceptance checklist. Build the release `.app`. Write the README run instructions.
- Update the DEVLOG with known issues.
- **Done when:** the user-facing launch command is provided.

---

# Phase 2 — Package and environment management (v0.2)

## Stage 8 — Environment model
- `PythonEnvironmentInfo` (id, name, kind managed/linked, root), `EnvironmentRegistry` (+ store): default *Default* env pointing at the existing `venv`, add/rename/remove/validate, per-file assignments, fallback to default.
- Refactor `PythonEnvironment` so create, install and inspect take an environment root. The existing default-env behaviour is unchanged. `MarimoServer` launches with `python -m marimo` in a given environment.
- **Tests:** registry rules and round-trip, name validation, slug uniqueness, creation commands, launch arguments. Existing integration tests still pass.
- **Done when:** the registry and the creation/inspection logic are covered by unit tests and the old flows still work.

## Stage 9 — PackageManager
- `list` (parse pip and uv JSON, tolerate noise), `install` (spec tokenizing and validation), `uninstall`, backend choice (uv vs pip, linked prefers pip), conda-meta detection, marimo protection.
- **Tests:** parsers with fixtures, commands via the fake runner, validation. **Integration (gated):** create an env, install and uninstall `six`.
- **Done when:** the whole package lifecycle works against a real environment.

## Stage 10 — Per-notebook environments
- `NotebookSession` carries its environment. Open and restore resolve the assignment. Switching environment restarts that tab. Toolbar picker. "Restart to apply" banner driven by package changes.
- **Done when:** two tabs run in two different environments at once.

## Stage 11 — UI
- Settings ▸ Environments (list + detail): packages table with filter/uninstall, install field, new/link/rename/default/remove. General tab keeps Marimo update and tool paths.
- Replace every placeholder-as-label with a real faint prompt (FR-UI-5).
- **Done when:** FR-PKG and FR-ENVR are all covered in the UI.

## Stage 12 — Verification and handoff
- Run acceptance items 8–9, smoke-test the real app (processes, restore, quit), rebuild the `.app`, update the DEVLOG with known issues.
