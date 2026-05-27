# VeilWriter Product Overview

## Positioning

VeilWriter is a lightweight macOS editor focused on quick project browsing, fast text loading, simple saving, and syntax-highlighted editing without the weight of a full IDE.

VeilWriter is configured for non-App-Store distribution without App Sandbox so it can access local project files with fewer permission interruptions.

## Current Capabilities

- Browse a selected folder through a native sidebar file tree.
- Select files from compact full-width sidebar rows for easier clicking.
- Open files and folders from either the menu commands or the empty sidebar state.
- Open text files, source files, and folders from Finder's Open With menu.
- Open individual files from the File menu.
- Reveal the current file in Finder with Open Containing Folder.
- Open bundled macOS Help from the system Help menu for core workflows and troubleshooting.
- Install the `veilwriter` command line tool from Settings into `~/.local/bin` and open files or folders from Terminal.
- Reopen recent files and folders from the empty sidebar state with readable sidebar spacing.
- Keep temporary test and scratch paths out of recent files and folders.
- Restore the last folder, open tabs, active tab, and a pinned-expanded root file tree on launch with security-scoped folder access.
- Run common actions from the Command-Shift-P command palette with keyboard selection and highlighted rows.
- Search and open project files quickly with Command-P.
- Keep multiple files open in tabs, each with its own unsaved state.
- Switch tabs with previous/next commands or Command-1 through Command-9.
- Reopen the most recently closed tab with Command-Shift-T.
- Open multiple windows, each with its own independent tab set and editor state.
- Close the active tab from the File menu or with Option-Tab.
- Jump to a specific line with Command-L.
- Jump to symbols in the active file with Command-Shift-O.
- Find and replace text in the active editor, all open tabs, or the selected folder with highlighted matches and next/previous navigation.
- Use the right inspector for a lightweight minimap and document/code structure view, with click-to-jump navigation into the current tab.
- Use Focus Mode to hide editor chrome when reading or writing.
- Open a lightweight split editor pane to view another text file beside the active editor.
- Preview Markdown beside the editor with richer block rendering for headings, lists, quotes, dividers, and fenced code.
- Read current file state from a compact status bar with cursor position, language, file size, and version.
- Reload when the active file has changed on disk outside VeilWriter.
- Read selected character and line counts from the status bar when text is selected.
- See lightweight dirty gutter marks for lines changed since the last saved content.
- Highlight matching bracket pairs around the cursor for common code delimiters.
- Open text files in a native macOS editing surface.
- Highlight Swift, Ruby, PHP, Java, JSON, JavaScript, TypeScript, Go, HTML, CSS, Markdown, Python, shell/bash, YAML, TOML, XML, SQL, Dockerfile, Makefile, INI, env, Rust, C, C++, and C# files.
- Customize editor font, font size, line height, color style, line numbers, and current-line focus highlighting from Settings with immediate editor refresh.
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
- Require explicit confirmation before loading larger files, with a core loader guard as a backstop.

## Open Questions

- Add line-number and search workflows without making the editor feel heavy.
- Add keyboard shortcuts for tab navigation and closing the current tab.
- Add deeper language-aware highlighting for embedded HTML/CSS/JS regions.
- Add keyboard-first refinements for replacing and selecting all find matches.
- Make structure items jump to their source lines.
- Decide whether very large files should open in read-only preview mode instead of the editable buffer.
