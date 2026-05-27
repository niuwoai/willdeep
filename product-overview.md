# VeilWriter Product Overview

## Positioning

VeilWriter is a lightweight macOS editor focused on quick project browsing, fast text loading, simple saving, and syntax-highlighted editing without the weight of a full IDE.

## Current Capabilities

- Browse a selected folder through a native sidebar file tree.
- Select files from compact full-width sidebar rows for easier clicking.
- Open files and folders from either the menu commands or the empty sidebar state.
- Open individual files from the File menu.
- Reopen recent files and folders from the empty sidebar state.
- Restore the last folder, open tabs, and active tab on launch.
- Run common actions from the Command-Shift-P command palette.
- Search and open project files quickly with Command-P.
- Keep multiple files open in tabs, each with its own unsaved state.
- Open multiple windows, each with its own independent tab set and editor state.
- Close the active tab from the File menu or with Option-Tab.
- Jump to a specific line with Command-L.
- Find and replace text in the active editor, all open tabs, or the selected folder with highlighted matches and next/previous navigation.
- Use the right inspector for a lightweight minimap and document/code structure view, with click-to-jump navigation into the current tab.
- Read current file state from a compact status bar with cursor position, language, file size, and version.
- See lightweight dirty gutter marks for lines changed since the last saved content.
- Highlight matching bracket pairs around the cursor for common code delimiters.
- Open text files in a native macOS editing surface.
- Highlight Swift, Ruby, PHP, Java, JSON, JavaScript, TypeScript, Go, HTML, CSS, Markdown, Python, shell/bash, YAML, TOML, XML, SQL, Dockerfile, Makefile, INI, env, Rust, C, C++, and C# files.
- Customize editor font, font size, color style, line numbers, and current-line focus highlighting from Settings.
- Keep indentation flowing with newline auto-indent plus Tab and Shift-Tab line indentation.
- Decode UTF-8 first, then fall back through NSString encoding detection and ISO Latin 1.
- Detect binary files before opening.
- Track dirty state, save with Cmd+S, and save copies with Save As.
- Warn before loading files larger than 1 MB.

## Performance Direction

- Keep file IO off the main thread.
- Apply completed file loads back on the main thread and target the tab that requested the load.
- Force the editor view to re-render after tab activation or closure so syntax highlighting remains visible.
- Keep the default editing path optimized for files under 1 MB.
- Require explicit confirmation before loading larger files, with a core loader guard as a backstop.

## Open Questions

- Add line-number and search workflows without making the editor feel heavy.
- Add keyboard shortcuts for tab navigation and closing the current tab.
- Add deeper language-aware highlighting for embedded HTML/CSS/JS regions.
- Add keyboard-first refinements for replacing and selecting all find matches.
- Make structure items jump to their source lines.
- Decide whether very large files should open in read-only preview mode instead of the editable buffer.
