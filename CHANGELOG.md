# Changelog

## 1.32.0-rc6 - 2026-06-01

- Fixed tab-switch scroll position drifting by ~one screenful upward on long files: scrolling to e.g. line 6600 in a tab, switching away and switching back used to land you on line ~6300. The restore path used `scrollRangeToVisible(saved top character)` which only guarantees the target is on screen — it would land at the bottom of the viewport, not the top. Now the saved top-of-viewport line is positioned at the top via `setBoundsOrigin` on the clip view, with layout ensured from offset 0 to the target character so the line fragment Y is exact (a fragment's Y depends on the heights of every fragment above it). Verified by instrumented measurement on an 8000-line file: scrolling to line 6596, switching tabs and back lands at actualLine=6596 (drift = 0 lines), vs ~-123 lines pre-fix.

## 1.32.0-rc5 - 2026-06-01

- Cut window re-activation lag on large files by ~66%, measured on a 348 KB file with structure inspector open: ~265 ms -> ~90 ms per re-activation. Found via main-thread sampling that two costs ran on every SwiftUI `updateNSView` (which re-fires on every window become-active):
  - `LineNumberRulerView.lineCount()` scanned the entire string to count newlines each call, and was invoked twice per update via `requiredThickness`. Now cached by string length, with an O(1) check that only recomputes when length changes.
  - The whole `applyAppearance` pass (font, theme, paragraph style, ruler retile) ran unconditionally, even when nothing changed. Now gated on `settingsChanged || langChanged || renderRevisionChanged`; the cheap `changedLineNumbers` update to the ruler still runs every time. The ruler also only calls `invalidateRuleThickness()` when the gutter's digit count would actually differ.

## 1.32.0-rc4 - 2026-06-01

- Fixed two regressions from the non-contiguous layout introduced in 1.32.0-rc2:
  - Clicking the Dock icon after switching to another app no longer takes several seconds to show the window. Non-contiguous (lazy) layout made AppKit re-layout on window re-activation and was the cause; it has been removed. The tab-switch speedup it was meant to provide actually came from not forcing a full-document layout pass on switch (the `preserveViewport`/`scrollRangeToVisible` changes), which remain in place.
  - Folding a scope on a file with ~1000+ lines was still slow. The layout-manager delegate calls `isFoldedGlyphRange` for every line fragment it lays out, and that recomputed every folded range from scratch each time (each an O(file) line scan) — O(folds × file) per layout pass. Folded character ranges are now cached and rebuilt only when the fold set or text changes.

## 1.32.0-rc3 - 2026-06-01

- Fixed the ~1 second delay when clicking a gutter fold control on a large file. Toggling a fold invalidated glyphs and layout for the *entire* document starting at offset 0; once non-contiguous layout was enabled (1.32.0-rc2), that forced TextKit to re-lay-out everything visible from the top. Folding only affects lines from the fold's start downward, so invalidation now begins at the earliest folded scope instead of the document start — content above the fold keeps its layout. Unfolding re-validates from the previously-folded start so reappearing content lays out correctly.

## 1.32.0-rc2 - 2026-06-01

- Further reduced tab-switch lag on large files. Instrumented measurement showed the model update was already trivial (2-7 ms) and the plain-text apply was 50-180 ms, but the editor's render commit took 300-1000 ms — dominated by TextKit laying out the whole document. Changes: (1) enabled non-contiguous (lazy) layout so only the visible glyphs are laid out instead of the entire file; (2) on a tab switch / fresh load, skip the viewport-anchor restore that forced a full-document `ensureLayout` (scroll is restored separately); (3) restore the tab's scroll position via `scrollRangeToVisible` on the saved top character (local layout only) instead of an absolute pixel offset that needed full layout; (4) count gutter lines over UTF-8 bytes instead of per-character NSString bridging. The inspector's structure-outline extraction and minimap line-split were also moved off the main thread (computed in a background task, only when shown) so the editor area appears immediately and the minimap/structure fill in just after.

## 1.32.0-rc1 - 2026-06-01

- Made switching between open tabs lighter: each tab now remembers its caret position and scroll offset, and switching back restores them instead of jumping to the top of the file. The position is captured live from the editor when switching away and restored after the incoming tab's content is in place (layout is forced first so the scroll offset isn't clamped against a not-yet-grown document height). Combined with the viewport highlighting from 1.31.0, switching to a large-file tab no longer re-highlights the whole document.

## 1.31.0-rc1 - 2026-06-01

- Added viewport-based syntax highlighting for large files. Files at or above ~100 KB now highlight only the visible range (expanded to line boundaries with an ~8 KB overscan margin) instead of running the regex over the whole document, and extend highlighting as you scroll (debounced). Highlight attributes are applied in place rather than swapping the whole text storage, so scroll position and layout are preserved. Smaller files keep the existing whole-file async highlight. Net effect: very large files open and scroll smoothly; the color pass for an off-screen region arrives a beat after it scrolls into view. Edits and Go to Symbol jumps re-highlight the visible range.

## 1.30.0-rc2 - 2026-06-01

- Fixed files taking many seconds to appear when opened (a large file could freeze the window for 10+ seconds). The editor ran a full-file syntax-highlight regex pass synchronously on the main thread *before* displaying any content — and then highlighted the same text again asynchronously, doing the heavy work twice. Now the file's plain text is shown instantly the moment it loads, and syntax highlighting is computed off the main thread and swapped in when ready. Opening a file is responsive immediately; the color pass arrives a beat later. Minimap, inspector outline, and scope-guide computations were already lazy/cached and are unaffected.

## 1.30.0-rc1 - 2026-06-01

- Added a cross-session disk cache for the Quick Open file list (Command+P). Previously the panel re-walked the entire project tree (FileManager enumerator, capped at 1500 files) synchronously on every keystroke, stalling on large projects. The file list is now scanned once into a cache under `~/Library/Caches/<bundle-id>/projects/<sha256-of-root-path>/filelist.json`, served instantly from cache when a project re-opens, and verified by a background scan that backfills any differences. Invalidation is layered and cheap (modification time + size per entry; no content hashing). The cache lives outside the project directory so it never pollutes the user's git tree, and keeps at most the 50 most-recently-used project caches. Quick Open keystrokes now filter an in-memory array instead of touching disk.

## 1.29.0-rc3 - 2026-06-01

- Improved Go to Symbol (Command+Shift+O) responsiveness on large files: the outline extraction (regex passes over the whole file) is now computed once when the panel opens and recomputed only when the file content or language actually changes, instead of on every body evaluation. Arrow-key navigation and typing in the query field no longer re-parse the entire file each interaction. Query filtering still happens live against the cached outline.

## 1.29.0-rc2 - 2026-06-01

- Fixed the Go to Symbol panel not scrolling the highlighted row into view when arrowing past the visible window: the list now anchors scrolling on the stable row index instead of the per-item UUID, which was regenerated on every body evaluation and never matched the rendered ids (so the scroll silently no-opped).

## 1.29.0-rc1 - 2026-06-01

- Added arrow-key navigation to the Go to Symbol panel (Command+Shift+O), matching the Command Palette: Up/Down move the selection, Return jumps to the highlighted symbol, the selected row is highlighted and scrolled into view, and hover selection is suppressed briefly after a keyboard move.

## 1.28.0-rc4 - 2026-06-01

- Fixed the editor viewport jumping after an edit (scrolling to the top, or drifting a few lines up) by anchoring on the character at the top of the viewport and re-pinning it after layout settles, instead of restoring a raw pixel scroll offset that gets clamped against the transiently-collapsed document height during a re-highlight.
- Fixed severe arrow-key cursor-movement lag by skipping the full-document glyph/layout invalidation on every caret move and clearing only the previously highlighted bracket ranges instead of sweeping the entire document's temporary attributes.
- Fixed scroll/edit sluggishness on large files by memoizing the fold-guide scope analysis (previously the line-number gutter re-parsed the whole document on every redraw) and computing visible line numbers incrementally instead of rescanning from the file start for each gutter row.

## 1.28.0-rc3 - 2026-05-31

- Fixed Escape closing behavior for Quick Open, Go to Line, and Go to Symbol floating panels so shortcut-opened navigation windows dismiss consistently.

## 1.28.0-rc2 - 2026-05-28

- Fixed folded editor ranges leaking across tab switches by clearing visual folds before programmatic tab text refreshes.

## 1.28.0-rc1 - 2026-05-28

- Added gutter folding controls for collapsible code scopes while disabling visible scope guide line rendering.

## 1.27.0-rc1 - 2026-05-28

- Added lightweight scope guide rendering for supported syntax-highlighted languages, including Ruby, Python, Java, brace-based languages, markup, and section-style formats.

## 1.26.0-rc1 - 2026-05-28

- Added an editor context menu for choosing automatic, plain text, or explicit syntax highlighting languages per tab.

## 1.25.0-rc2 - 2026-05-28

- Fixed New Window so Command-N prompts for a folder and opens the selected directory in the new window instead of restoring an already-open project.

## 1.25.0-rc1 - 2026-05-28

- Added a File menu New Tab command with Command-T for opening a fresh untitled editor tab.

## 1.24.0-rc4 - 2026-05-27

- Fixed folder opening from the app UI and external folder events so selected directories open in a new editor window instead of replacing the current window.

## 1.24.0-rc3 - 2026-05-27

- Fixed HTML outline extraction so unlabeled ul and ol list containers appear in the shallow structure outline.

## 1.24.0-rc2 - 2026-05-27

- Fixed a crash when HTML outline extraction reads id, class, title, or aria-label attributes with different quote styles.

## 1.24.0-rc1 - 2026-05-27

- Added HTML preview support beside the editor using the existing lightweight preview pane.
- Reworked HTML outline extraction to use shallow HTML node structure, including title, h1-h5, div, list, and semantic layout nodes.

## 1.23.0-rc6 - 2026-05-27

- Fixed Command-W in editor windows so it closes the active tab before falling back to the system window-close behavior when no tab is open.

## 1.23.0-rc5 - 2026-05-27

- Fixed Settings window keyboard handling so Option-W and Command-W close the Settings window when it is focused.

## 1.23.0-rc4 - 2026-05-27

- Added a sidebar image preview flow so double-clicking common raster image files shows them in the editor detail area instead of treating them as text.

## 1.23.0-rc3 - 2026-05-27

- Fixed sidebar folder Git markers flickering between untracked and deleted states by expanding untracked directories and aggregating child statuses deterministically.

## 1.23.0-rc2 - 2026-05-27

- Fixed command palette keyboard navigation flickering and snapping back to hovered bottom rows while scrolling the selected command into view.

## 1.23.0-rc1 - 2026-05-27

- Added SF Symbols-based file type icons with subtle colors for common source, web, config, media, archive, database, build, and project files in the sidebar tree.

## 1.22.0-rc2 - 2026-05-27

- Fixed editor appearance refreshes overwriting existing rich-text syntax highlight colors during SwiftUI updates.

## 1.22.0-rc1 - 2026-05-27

- Added Settings controls for sidebar file-tree text size, the default Inspector view, and Minimap/Structure ordering.
- Applied sidebar text-size changes immediately to file-tree rows.
- Preserved older saved editor settings while filling in new sidebar and inspector preference defaults.

## 1.21.0-rc2 - 2026-05-27

- Fixed Git status refresh running synchronously on the main thread and publishing changes during SwiftUI view updates.

## 1.21.0-rc1 - 2026-05-27

- Added lightweight Git integration with current branch display and sidebar file status markers.
- Added sidebar context actions for new files, new folders, Finder reveal, Terminal launch, and path copying.
- Added command palette fuzzy matching, keyword lookup, shortcut hints, and Terminal/path/Git refresh actions.

## 1.20.0-rc4 - 2026-05-27

- Added left and right breathing room around Recent Files and Recent Folders in the empty sidebar state.

## 1.20.0-rc3 - 2026-05-27

- Fixed editor theme and appearance changes from Settings not immediately refreshing the active editor.

## 1.20.0-rc2 - 2026-05-27

- Filtered temporary files and folders out of Recent Files and Recent Folders, including cleanup of previously saved temporary paths.

## 1.20.0-rc1 - 2026-05-27

- Disabled App Sandbox for the main VeilWriter app target to allow broader local filesystem access in non-App-Store builds.

## 1.19.0-rc2 - 2026-05-27

- Fixed command line tool installation by writing `veilwriter` to `~/.local/bin` without administrator authorization.
- Saved security-scoped access for restored project folders so the sidebar tree can reload after launching the app again.

## 1.19.0-rc1 - 2026-05-27

- Registered VeilWriter as an alternate Finder "Open With" app for text documents, source files, and folders.

## 1.18.0-rc1 - 2026-05-27

- Added keyboard selection to the command palette with Up/Down navigation, Return execution, and a highlighted selected row.

## 1.17.0-rc1 - 2026-05-27

- Added a Settings entry to install or update the `veilwriter` command line tool at `/usr/local/bin/veilwriter`.
- Added external file and folder open handling so the CLI can launch VeilWriter directly into a path.

## 1.16.0-rc5 - 2026-05-27

- Added a bundled macOS Help Book so VeilWriter Help opens from the system Help menu instead of showing the missing-help alert.

## 1.16.0-rc4 - 2026-05-27

- Kept the restored project root visually expanded in the sidebar so its file tree loads immediately on launch.

## 1.16.0-rc3 - 2026-05-27

- Fixed restored project folders not expanding and loading their file tree immediately on app launch.

## 1.16.0-rc2 - 2026-05-27

- Forced a dedicated syntax-highlight refresh after file loads and tab activation so shell and HTML files render highlighted immediately.

## 1.16.0-rc1 - 2026-05-27

- Added an editor line-height preference and applied it to the text view layout.
- Tightened sidebar file-tree rows for denser project browsing while preserving full-row click targets.
- Reworked Markdown preview into a richer block renderer for headings, paragraphs, quotes, lists, dividers, and fenced code blocks.

## 1.15.0-rc1 - 2026-05-27

- Added external file change detection with a status bar reload action.
- Added Focus Mode to hide editor chrome for a cleaner writing and reading surface.
- Added lightweight split editor support for viewing another text file beside the active editor.
- Added Markdown preview and an Open Containing Folder command.

## 1.14.0-rc1 - 2026-05-27

- Added optional save cleanup settings for trimming trailing whitespace and ensuring a final newline.
- Added status bar selection info for selected character and line counts.
- Added Duplicate Line, Move Line Up, and Move Line Down commands with keyboard shortcuts and command palette entries.

## 1.13.0-rc1 - 2026-05-27

- Added Command-Shift-O symbol jump for searching and navigating the active file outline.
- Added previous/next tab commands and Command-1 through Command-9 indexed tab activation.
- Added Command-Shift-T to reopen the most recently closed tab.

## 1.12.0-rc1 - 2026-05-27

- Added a Command-Shift-P command palette for fast editor actions.
- Added recent files and recent folders with quick access from the empty sidebar state.
- Added session restore for the last folder, open tabs, and active tab.
- Added a lightweight dirty gutter indicator for lines that differ from the saved file content.
- Added bracket pair highlighting around the cursor for parentheses, square brackets, and braces.

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
