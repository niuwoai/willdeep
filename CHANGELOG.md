# Changelog

## 1.11.0-rc1 - 2026-05-27

- Added Quick Open with Command-P for fast file lookup inside the selected folder.
- Added Go to Line with Command-L, reusing editor line navigation.
- Added a compact status bar with modified state, cursor line/column, language, file size, and app version.
- Added lightweight indentation helpers for newline indentation, Tab indent, and Shift-Tab outdent.

## 1.10.0-rc1 - 2026-05-27

- Made the right inspector navigable: minimap rows and structure items now jump the current editor tab to the selected line.

## 1.9.0-rc5 - 2026-05-27

- Forced editor re-rendering after tab activation and closure so the remaining tab keeps syntax highlighting.

## 1.9.0-rc4 - 2026-05-27

- Changed the close-current-tab shortcut from Option-W to Option-Tab.

## 1.9.0-rc3 - 2026-05-27

- Added a narrow collapsed inspector rail so the right sidebar can be reopened after hiding it.

## 1.9.0-rc2 - 2026-05-27

- Fixed newly opened files briefly appearing unhighlighted by applying an immediate synchronous highlight before the background refresh.

## 1.9.0-rc1 - 2026-05-27

- Expanded bash/shell syntax highlighting for shebangs, variables, assignments, flags, command substitutions, functions, and common builtins.
- Added syntax highlighting and extension detection for YAML, TOML, XML, SQL, Dockerfile, Makefile, INI, env, Rust, C, C++, and C#.
- Added filename detection for common shell/config files such as `.bashrc`, `.zshrc`, `.env`, `Dockerfile`, and `Makefile`.

## 1.8.0-rc1 - 2026-05-27

- Added a right-side editor inspector with Minimap and Structure views.
- Added lightweight structure extraction for supported source and document languages.
- Added an Option-Command-I shortcut to show or hide the inspector.

## 1.7.0-rc1 - 2026-05-27

- Added find/replace scope selection for the current tab, all open tabs, or the selected folder.
- Added selected-folder tracking in the file tree for folder-scoped replace-all operations.
- Added independent per-window editor state so each window can own its own tab set.

## 1.6.0-rc1 - 2026-05-27

- Added an in-editor find and replace bar with match highlighting, next/previous navigation, replace current, and replace all.
- Added Command-F, Command-G, and Shift-Command-G commands for find workflows.
- Made editor theme/font changes discard stale highlight results so the visible editor re-renders with the latest settings.

## 1.5.0-rc1 - 2026-05-27

- Added an Option-W shortcut and File menu command for closing the current editor tab.

## 1.4.0-rc5 - 2026-05-27

- Tightened sidebar file-tree row height and made each file row a full-width button target.

## 1.4.0-rc4 - 2026-05-27

- Replaced the empty-sidebar icon buttons with a quieter custom style that avoids the default focus ring.

## 1.4.0-rc3 - 2026-05-27

- Fixed file-tree rows so the full row width responds to clicks, not just the filename text.

## 1.4.0-rc2 - 2026-05-27

- Fixed the empty editor area showing an insertion caret before any file is open.
- Added separate empty-sidebar actions for opening a file or opening a folder.

## 1.4.0-rc1 - 2026-05-27

- Added syntax highlighting support for Ruby, PHP, Java, and Go.
- Expanded extension detection for JavaScript, TypeScript, HTML, CSS, and JSON variants.
- Added regression coverage for requested language detection and keyword highlighting.

## 1.3.0-rc2 - 2026-05-27

- Fixed a launch/open-file crash risk by keeping `AppState` mutations on the main thread during background file loading.
- Made asynchronous file loading update the matching tab instead of whichever tab is active when the read completes.

## 1.3.0-rc1 - 2026-05-27

- Added multi-tab editing so multiple files can stay open at once.
- Preserved per-tab dirty state and content while switching between open files.
- Added tab close controls with unsaved-change confirmation.

## 1.2.0-rc1 - 2026-05-27

- Added File menu support for opening individual files.
- Replaced the default save menu group with working Save and Save As commands.
- Added Save As support for untitled or relocated files.

## 1.1.0-rc2 - 2026-05-27

- Renamed the app-facing product to VeilWriter.
- Imported the VeilWriter logo assets into the macOS AppIcon asset catalog.

## 1.1.0-rc1 - 2026-05-27

- Added editor appearance settings for font family, font size, color style, line numbers, and current-line focus highlighting.
- Added built-in color styles and wired syntax highlighting colors to the selected style.
- Added line numbers in the editor gutter with current-line emphasis.

## 1.0.0-rc2 - 2026-05-27

- Made the empty folder state clickable so it opens the directory picker directly.
- Reused the same folder-opening flow for the empty state and the menu command.

## 1.0.0-rc1 - 2026-05-27

- Improved file loading performance safeguards by enforcing the 1 MB default loading limit inside `AppState.loadFile`.
- Added a shared large-file confirmation helper so UI checks and core loading behavior stay aligned.
- Added c1 regression coverage for full asynchronous file loading under 500 ms and large-file rejection.
- Fixed existing compile blockers in editor highlighting and syntax range tracking.
