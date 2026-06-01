# VeilWriter Product Overview

> Last updated: 2026-06-01 | Current version: v1.31.0-rc1

## Positioning

VeilWriter is a lightweight macOS editor focused on quick project browsing, fast text loading, simple saving, and syntax-highlighted editing without the weight of a full IDE.

VeilWriter is configured for non-App-Store distribution without App Sandbox so it can access local project files with fewer permission interruptions.

## Current Capabilities

- Browse a selected folder through a native sidebar file tree.
- Recognize common file types in the sidebar through colored SF Symbols-based icons.
- Preview common raster image files from the sidebar by double-clicking them.
- Select files from compact full-width sidebar rows for easier clicking.
- See lightweight Git file markers in the sidebar and the current branch in the status bar.
- Create files and folders from the sidebar context menu.
- Reveal sidebar items in Finder, open Terminal at their folder, and copy absolute or relative paths.
- Open files from the current window and open folders into separate editor windows from menu commands, recent folders, the command palette, or the empty sidebar state.
- Open text files, source files, and folders from Finder's Open With menu.
- Open individual files from the File menu.
- Open a new window by choosing the folder that window should browse.
- Create a fresh untitled editor tab from the File menu or with Command-T.
- Reveal the current file in Finder with Open Containing Folder.
- Open bundled macOS Help from the system Help menu for core workflows and troubleshooting.
- Install the `veilwriter` command line tool from Settings into `~/.local/bin` and open files or folders from Terminal.
- Reopen recent files and folders from the empty sidebar state with readable sidebar spacing.
- Keep temporary test and scratch paths out of recent files and folders.
- Restore the last folder, open tabs, active tab, and a pinned-expanded root file tree on launch with security-scoped folder access.
- Run common actions from the Command-Shift-P command palette with keyboard selection, highlighted rows, fuzzy matching, keyword lookup, and shortcut hints.
- Open Terminal, copy active-file paths, and refresh Git status from the command palette.
- Search and open project files quickly with Command-P.
- Keep multiple files open in tabs, each with its own unsaved state.
- Switch tabs with previous/next commands or Command-1 through Command-9.
- Reopen the most recently closed tab with Command-Shift-T.
- Open multiple windows, each with its own independent tab set and editor state.
- Close the active tab from the File menu or with Command-W.
- Jump to a specific line with Command-L.
- Jump to symbols in the active file with Command-Shift-O.
- Find and replace text in the active editor, all open tabs, or the selected folder with highlighted matches and next/previous navigation.
- Use the right inspector for a lightweight minimap and document/code structure view, with click-to-jump navigation into the current tab.
- Choose the default right inspector view and whether Minimap or Structure appears first in the Inspector control.
- Use Focus Mode to hide editor chrome when reading or writing.
- Open a lightweight split editor pane to view another text file beside the active editor.
- Preview Markdown and HTML beside the editor with richer lightweight block rendering for headings, lists, quotes, dividers, code, and common HTML content nodes.
- Read current file state from a compact status bar with cursor position, language, file size, and version.
- Reload when the active file has changed on disk outside VeilWriter.
- Read selected character and line counts from the status bar when text is selected.
- See lightweight dirty gutter marks for lines changed since the last saved content.
- Highlight matching bracket pairs around the cursor for common code delimiters.
- Fold and expand detected code scopes from the line-number gutter without changing the underlying file content.
- Open text files in a native macOS editing surface.
- Highlight Swift, Ruby, PHP, Java, JSON, JavaScript, TypeScript, Go, HTML, CSS, Markdown, Python, shell/bash, YAML, TOML, XML, SQL, Dockerfile, Makefile, INI, env, Rust, C, C++, and C# files.
- Override syntax highlighting per editor tab from the editor context menu.
- Extract language-aware document structure, including shallow HTML node outlines for title, h1-h5, div, list, and semantic layout elements.
- Customize editor font, font size, line height, sidebar file-tree text size, color style, line numbers, current-line focus highlighting, and inspector preferences from Settings with immediate refresh.
- Optionally trim trailing whitespace and ensure a final newline on save.
- Keep indentation flowing with newline auto-indent plus Tab and Shift-Tab line indentation.
- Duplicate the current line with Command-D and move it with Option-Up/Option-Down.
- Decode UTF-8 first, then fall back through NSString encoding detection and ISO Latin 1.
- Detect binary files before opening.
- Track dirty state, save with Cmd+S, and save copies with Save As.
- Warn before loading files larger than 1 MB.

## Performance Direction

- Keep file IO off the main thread.
- Apply completed file loads back on the main thread and target the tab that requested the load.
- Force the editor view to re-render after tab activation or closure so syntax highlighting remains visible.
- Expand and load the restored project root as soon as the sidebar tree appears.
- Keep the default editing path optimized for files under 1 MB.
- Show a file's plain text immediately on open; never block the main thread on a full-file syntax-highlight pass. Highlighting runs off the main thread and is swapped in when ready.
- For large files (>= ~100 KB), highlight only the visible range plus an overscan margin and extend on scroll, applying attributes in place so scroll/layout are preserved. Smaller files highlight the whole document once.
- Require explicit confirmation before loading larger files, with a core loader guard as a backstop.
- Cache the Go to Symbol outline when the panel opens (recompute only when file content or language changes) so arrow-key navigation and query typing don't re-run the regex extraction on every body pass.
- Cache the Quick Open file list cross-session on disk (in `~/Library/Caches`, outside the project directory) keyed by a SHA-256 of the project root path. Serve it instantly on project open, verify it with a background scan, and invalidate per-entry by modification time + size (no content hashing). Cap the cache at the 50 most-recently-used projects.

## Open Questions

- Decide whether the Quick Open / file-list cache should honor `.gitignore` (currently it mirrors the raw enumerator walk).
- Extend the cross-session disk cache to the Go to Symbol outline (currently cached only in-memory per panel session).

- Add line-number and search workflows without making the editor feel heavy.
- Refine keyboard-first tab workflows around unsaved-change prompts and bulk closing.
- Add deeper language-aware highlighting for embedded HTML/CSS/JS regions.
- Add keyboard-first refinements for replacing and selecting all find matches.
- Make structure items jump to their source lines.
- Decide whether very large files should open in read-only preview mode instead of the editable buffer.
