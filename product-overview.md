# VeilWriter Product Overview

## Positioning

VeilWriter is a lightweight macOS editor focused on quick project browsing, fast text loading, simple saving, and syntax-highlighted editing without the weight of a full IDE.

## Current Capabilities

- Browse a selected folder through a native sidebar file tree.
- Select files from full-width sidebar rows for easier clicking.
- Open files and folders from either the menu commands or the empty sidebar state.
- Open individual files from the File menu.
- Keep multiple files open in tabs, each with its own unsaved state.
- Open text files in a native macOS editing surface.
- Highlight Swift, Ruby, PHP, Java, JSON, JavaScript, TypeScript, Go, HTML, CSS, Markdown, Python, and shell files.
- Customize editor font, font size, color style, line numbers, and current-line focus highlighting from Settings.
- Decode UTF-8 first, then fall back through NSString encoding detection and ISO Latin 1.
- Detect binary files before opening.
- Track dirty state, save with Cmd+S, and save copies with Save As.
- Warn before loading files larger than 1 MB.

## Performance Direction

- Keep file IO off the main thread.
- Apply completed file loads back on the main thread and target the tab that requested the load.
- Keep the default editing path optimized for files under 1 MB.
- Require explicit confirmation before loading larger files, with a core loader guard as a backstop.

## Open Questions

- Add line-number and search workflows without making the editor feel heavy.
- Add keyboard shortcuts for tab navigation and closing the current tab.
- Add deeper language-aware highlighting for embedded HTML/CSS/JS regions.
- Decide whether very large files should open in read-only preview mode instead of the editable buffer.
