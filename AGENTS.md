# AGENTS.md — macOS Swift development rules

Instructions for any AI agent (or human) working in this repository. Read SPECIFICATION.md, WORKPLAN.md and SKILLS.md first.

## 1. Workflow (mandatory)
1. Work stage by stage from WORKPLAN.md. Do not start a stage before the previous one is committed.
2. **Commit after every stage** (and after any significant fix). Each commit must build and pass tests.
3. Commit identity is `claude-sonnet <noreply@anthropic.com>`, set in the repo-local git config. Never change global git config.
4. Commit messages: `Stage N: short summary` or `fix: …`, followed by a body and the co-author trailer if the harness requires one.
5. **Log in DEVLOG.md** every stage start/finish and every key decision (what, why, alternatives rejected). Append only; newest at the bottom, with date.
6. Update the status table in WORKPLAN.md when a stage changes state.
7. When the spec and reality disagree, fix the spec in the same commit and record why in DEVLOG.md.
8. Operate autonomously. Ask the user only when a decision is irreversible, costs money, needs credentials, or contradicts the spec.

## 2. Platform and tooling
- Swift 6 language mode, strict concurrency. Target macOS 26. Use SwiftUI first and AppKit (`NSViewRepresentable`, `NSOpenPanel`, `NSSavePanel`) only where SwiftUI lacks capability.
- Build with SwiftPM only (`swift build`, `swift test`). Assemble the app with `scripts/build_app.sh`. Do not add an `.xcodeproj`.
- Only Command Line Tools may be installed (no full Xcode). Do not rely on Xcode-only features (asset catalogs via `actool`, SwiftUI previews). Generate the icon with `iconutil` or a script.
- No third-party Swift dependencies without a DEVLOG justification. Prefer Foundation, SwiftUI, WebKit and Observation.

## 3. Architecture rules
- UI-free logic goes in `MarimoCore` and must be unit-testable. Views contain no process, file or network code.
- State lives in `@Observable @MainActor` models. Pass dependencies in through initializers (protocols for process runner, file system and clock) so tests can fake them.
- Use `async/await` and structured concurrency. No `DispatchQueue` unless an API requires it. No force unwraps, `try!` or `fatalError` in shipped paths.
- Every spawned `Process` must be tracked and terminated on tab close, app quit and next-launch reap.
- Errors are typed (`enum …: LocalizedError`) and surfaced to the user. Never swallow an error silently.
- Log with `os.Logger` (subsystem `dev.marimodesktop`). No `print` in library code.

## 4. Styling rules (latest macOS look)
- Use system materials and Liquid Glass (`glassEffect`, `.containerBackground`, `.toolbarBackgroundVisibility`) rather than custom fills.
- System fonts, SF Symbols, semantic colors (`.primary`, `.secondary`, `Color(nsColor:)`), and both light and dark mode. Respect Reduce Transparency and Reduce Motion.
- Standard macOS idioms: menu-bar commands with shortcuts, `NavigationSplitView`, `.inspector`, sheets for modal flows, native alerts for errors.
- Accessibility labels on every icon-only control.
- **Placeholders:** example text in inputs must be a real faint prompt that vanishes on typing: `TextField("", text: $x, prompt: Text("e.g. …")).labelsHidden()`. Never pass the example as the title of a `TextField` inside a `Form` (it renders as a label beside the text).

## 5. Testing rules
- New logic ships with tests (Swift Testing or XCTest, whichever the installed toolchain supports). A bug fix adds a regression test first.
- Parsers use fixture strings. Git tests use a temp repo. Marimo integration tests are gated behind an environment variable (`MARIMO_INTEGRATION=1`) so the default `swift test` is fast and offline.
- Before each commit: `swift build -c release` (zero warnings) and `swift test` must pass.
- UI verification: build the app, launch it, and exercise the flow. Do not claim UI behaviour is verified if you only compiled it.

## 6. Security and safety
- Servers bind to 127.0.0.1 only. Never expose a token or log user notebook content.
- Validate and quote all paths passed to subprocesses (use argument arrays, never a shell string).
- Do not delete user files. Untitled notebooks live in a managed folder, and Save As copies and then removes only the managed temp file.
- Don't commit build products, venvs or secrets. Keep `.gitignore` current.

## 7. Documentation
- Public types and non-obvious functions get a short doc comment saying why, not what.
- README.md holds user-facing build/run instructions and must always be accurate.
