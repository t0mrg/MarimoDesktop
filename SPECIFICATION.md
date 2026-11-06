# Marimo Desktop — Specification

Version 0.2 · 2026-11-06

## 1. Purpose

Marimo Desktop is a native macOS app that wraps the Python [Marimo](https://marimo.io) reactive notebook framework. It gives Marimo a Mac-native shell: real windows, tabs, menus, file dialogs, keyboard shortcuts, a variable inspector and a Git panel. Marimo's own web UI renders each notebook. The native app manages everything around it.

## 2. Decisions (agreed with the user)

| Topic | Decision |
|---|---|
| Python / Marimo | **Managed venv.** On first launch the app finds `uv` (preferred) or `python3` (≥3.9). It creates a private venv in `~/Library/Application Support/MarimoDesktop/venv` and installs `marimo` there. It never touches the user's global Python. |
| Variable browser | **Native SwiftUI inspector** fed live from each running notebook (see §6). |
| Platform | **macOS 26 (Tahoe)**, Swift 6, SwiftUI with AppKit where needed, Liquid Glass styling. |
| Build | **Swift Package Manager** plus `scripts/build_app.sh`, which assembles and ad-hoc signs `MarimoDesktop.app`. No `.xcodeproj`. |
| Environments (v0.2) | **Managed + linked.** Named managed venvs live in `…/MarimoDesktop/envs/`. Existing venv or conda environments can be linked by folder. The original `venv` becomes the environment named *Default*. |
| Environment choice (v0.2) | **Per notebook, remembered by file path.** New notebooks use the default environment. Switching restarts that notebook's kernel. |
| Package changes (v0.2) | Notebooks using the changed environment show **Restart to apply**. Nothing restarts automatically. |
| Package backend (v0.2) | `uv pip` for managed environments when uv exists, otherwise `python -m pip`. Linked environments prefer `python -m pip` (conda: pip only; conda-installed packages are listed but cannot be uninstalled here). |
| Git plugin | **Core workflow** via the `git` CLI: branch, status, diff, stage/unstage, commit, log, pull/push. |

## 3. Architecture

```
MarimoDesktop (executable, SwiftUI App)
 └─ MarimoCore (library, UI-free, unit-tested)
      ├─ PythonEnvironment   locate uv/python, create venvs, inspect health, install/upgrade marimo
      ├─ EnvironmentRegistry named environments, default, per-notebook assignments (persisted)
      ├─ PackageManager      list / install / uninstall packages in one environment
      ├─ MarimoServer        one `marimo edit --headless` process per open notebook
      ├─ PortAllocator       free localhost ports
      ├─ NotebookTemplate    new-notebook source
      ├─ VariableMirror      kiosk-mode WebSocket client → [Variable]
      └─ GitClient           async wrapper over /usr/bin/git, parsers
```

- **One server process per tab.** Each notebook gets its own `marimo edit --headless --no-token --host 127.0.0.1 --port N <file>` process. A tab is a `NotebookSession` that owns the process, a `WKWebView` and a `VariableMirror`. This isolates kernels and crashes. Closing a tab terminates its process. Quitting terminates all of them.
- **Security.** Servers bind to `127.0.0.1` only and use ephemeral ports. The web view is restricted to that origin. External links open in the default browser.
- **State.** `AppModel` (`@Observable`, `@MainActor`) holds the tabs, the selection, the environment status and the settings. The UI is a pure function of this model.

## 4. Functional requirements

### 4.1 Environment setup (FR-ENV)
- FR-ENV-1: On launch, check for a working venv with marimo. If it is missing, show a setup screen with progress and a log, then install automatically.
- FR-ENV-2: Show a clear error with recovery actions when neither `uv` nor Python is found (the options are install guidance, choosing a Python manually, and retry).
- FR-ENV-3: Settings pane shows the Marimo version and offers "Update Marimo" and "Rebuild environment".
- FR-ENV-4: Users can install extra packages into the venv (a simple field in Settings).

### 4.2 Tabs (FR-TAB)
- FR-TAB-1: Multiple notebooks open in tabs in a single window. Tabs can be reordered, closed with ⌘W and cycled with ⌃⇥ / ⌘⇧[ ⌘⇧].
- FR-TAB-2: Each tab shows the file name and a status (starting, running, error). Marimo autosaves after 1 s, so there is no separate dirty indicator.
- FR-TAB-3: Opening a file already open focuses its tab.
- FR-TAB-4: Closing a tab saves it first. Untitled notebooks with content prompt to Save As, Discard or Cancel.
- FR-TAB-5: Open tabs restore on relaunch (the file list is persisted).

### 4.3 File operations (FR-FILE)
- FR-FILE-1: **New** (⌘N) creates an untitled notebook. It is a real temp file in a managed Untitled folder, using a starter template.
- FR-FILE-2: **Open…** (⌘O) uses `NSOpenPanel` for `.py` files, with an Open Recent menu. Drag a file onto the window or Dock icon to open it. Finder "Open With" works through the registered document type.
- FR-FILE-3: **Save** (⌘S) asks Marimo to save through its API.
- FR-FILE-4: **Save As…** (⇧⌘S) uses `NSSavePanel` and writes the notebook to the new location. The tab then re-points to the new file.
- FR-FILE-5: Untitled notebooks prompt with Save As the first time they are saved.
- FR-FILE-6: External file changes are picked up (Marimo `--watch`).

### 4.4 Variable browser (FR-VAR)
- FR-VAR-1: A right-hand inspector (toggle ⌥⌘I) lists the variables of the active notebook: name, type, value preview and the defining cell.
- FR-VAR-2: Live updates as cells run. Search/filter field. Sorted by name.
- FR-VAR-3: Click to copy a value. Empty and error states are shown.
- FR-VAR-4: Data is read through the kiosk WebSocket mirror (§6). It never alters the notebook.

### 4.5 Git plugin (FR-GIT)
- FR-GIT-1: A left sidebar tab shows the repo of the active notebook's folder: branch, ahead/behind, and changed files grouped as Staged / Changes / Untracked.
- FR-GIT-2: Stage and unstage per file (and all). Discard changes to a file, with confirmation.
- FR-GIT-3: Diff viewer with syntax-coloured unified diff.
- FR-GIT-4: Commit message box and Commit (⌘↩). Amend is not required.
- FR-GIT-5: History list (last 100 commits) with author, date and subject.
- FR-GIT-6: Pull and Push buttons with progress and error output. Branch switcher menu.
- FR-GIT-7: "Not a repository" state with an **Initialise Repository** button.
- FR-GIT-8: The panel refreshes on tab change, after a save and on app activation.

### 4.6 App shell (FR-UI)
- FR-UI-1: Liquid Glass styling (`glassEffect`, translucent toolbar and sidebar, concentric corners), system fonts, light and dark mode, SF Symbols.
- FR-UI-2: `NavigationSplitView` layout: sidebar (Git), content (tab bar + notebook), inspector (Variables).
- FR-UI-3: Full menu bar (File, Edit, View, Notebook, Window, Help) with standard shortcuts. Welcome screen with recent files when no tabs are open.
- FR-UI-4: Native alerts for errors. Nothing fails silently.
- FR-UI-5: Example text in any input is a **faint placeholder that disappears when the user types**. It must never be a visible label beside the typed text. In SwiftUI use `TextField("", text:, prompt: Text("e.g. …"))` with the label hidden.

### 4.7 Packages and environments (FR-PKG, FR-ENVR)
- FR-PKG-1: Settings ▸ Environments shows, for the selected environment, every installed package with its **name and version**, sorted by name, with a filter field and a count.
- FR-PKG-2: **Install**: a text field accepts one or more package specs separated by spaces or commas (`pandas`, `numpy>=2`, `altair[all]`). Install runs with live log output, a progress indicator and a clear error on failure. The list refreshes afterwards.
- FR-PKG-3: **Uninstall**: a per-row button (with confirmation) removes a package, and multi-select removes several. `marimo` cannot be uninstalled (the button is disabled, with an explanation). Packages installed by conda are listed but not removable, with an explanation.
- FR-PKG-4: Spec input is validated. Tokens starting with `-` (pip options) are rejected, and empty input disables the Install button.
- FR-PKG-5: After any install or uninstall, open notebooks that use that environment show a **Restart to apply** banner with a Restart button.
- FR-PKG-6: Install and list work on linked environments the same way (pip).
- FR-ENVR-1: The Environments list shows each environment's name, kind (Managed / Linked / conda badge), Python version, Marimo version, and the number of open notebooks using it.
- FR-ENVR-2: **New environment** (managed): name (validated, unique), optional "copy packages from" an existing environment. It creates a venv and installs Marimo, with progress.
- FR-ENVR-3: **Link existing…** picks a folder (a venv, or a conda env such as `…/miniconda3/envs/foo`). The app checks that `bin/python` runs. If Marimo is missing it offers to install it into that environment.
- FR-ENVR-4: **Rename**, **Set as default**, and **Remove**. Removing a managed environment deletes its folder after confirmation. Removing a linked one only unlinks it and never touches its files. The default environment and any environment used by an open tab cannot be removed. Notebooks that had a removed environment fall back to the default.
- FR-ENVR-5: The toolbar has an environment picker for the active notebook (checkmark on current), plus *Manage Environments…*. Choosing another environment saves the assignment for that file and restarts that notebook.
- FR-ENVR-6: Notebooks are launched with `<env>/bin/python -m marimo edit …` (not the `marimo` script), and `CONDA_PREFIX` is set for conda environments.
- FR-ENVR-7: Environment registry and assignments persist across launches. A missing environment folder is reported as an error on the tab, never silently replaced.

## 5. Non-functional requirements
- NFR-1: Notebook cold start under 5 s once the environment exists.
- NFR-2: No orphaned Python processes after quit or crash (children are tracked, and stale ones are reaped on the next launch via a PID file).
- NFR-3: All core logic is unit-tested without UI. Swift 6 strict concurrency, no warnings.
- NFR-4: The app sandbox is **off** (it must run Python and git). The hardened runtime is enabled for ad-hoc signing and the entitlements are documented.
- NFR-5: Logging goes through `os.Logger`. A diagnostics view shows the server log per tab.

## 6. Variable browser mechanism

Marimo's server accepts extra WebSocket clients in **kiosk mode** (`/ws?session_id=…&file=…&kiosk=true`). A kiosk client mirrors the live session without owning it. The kernel broadcasts `variables` (names, declaring cells) and `variable-values` (type and preview) messages. `VariableMirror` is that client. Each notebook session therefore feeds the native inspector without code injection or patching Marimo. If kiosk mirroring turns out to be unavailable in some Marimo version, the fallback is a small bootstrap Python module loaded with the venv's `PYTHONPATH`. Any change to this decision is recorded in DEVLOG.md.

## 7. Out of scope (v1)
App Store distribution and notarization, multi-window, a Marimo app (run mode) gallery, Windows/Linux, a built-in code editor, Git branching beyond switching. Using `conda`/`mamba` commands to manage packages, `pyproject`/lockfile based project environments, and Marimo's `--sandbox` mode.

## 8. Acceptance criteria
1. `scripts/build_app.sh` produces `build/MarimoDesktop.app`, which launches on macOS 26.
2. First launch builds the venv and installs marimo, then a new notebook opens in a tab.
3. Three notebooks can be open simultaneously and run independently.
4. New, Open and Save As work through native dialogs. Reopening restores the tabs.
5. Variables defined in a notebook appear in the inspector within about 1 s of running the cell.
6. In a Git repo, a change can be viewed, staged, committed and pushed from the panel.
7. `swift test` passes. Quitting leaves no `marimo` processes running.
8. (v0.2) Create an environment, install `six`, see it listed with its version, uninstall it, and see it disappear. Two notebooks can use two different environments at the same time. A linked conda or venv environment works. The picker and the Restart banner behave as in FR-ENVR-5 and FR-PKG-5.
9. (v0.2) Typing into any install or name field replaces the faint example text.
