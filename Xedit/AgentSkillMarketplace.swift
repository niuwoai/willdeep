//
//  AgentSkillMarketplace.swift
//  WillDeep
//
//  Static first-party skill marketplace catalog and local installer.
//

import Foundation

struct AgentSkillCredentialRequirement: Identifiable, Equatable {
    let id: String
    let label: String
    let detail: String
    let environmentVariable: String
    let isRequired: Bool
}

struct AgentSkillMarketplaceEntry: Identifiable, Equatable {
    let id: String
    let skillName: String
    let displayName: String
    let tagline: String
    let detail: String
    let version: String
    let author: String
    let category: String
    let tags: [String]
    let minimumAppVersion: String
    let skillDescription: String
    let skillBody: String
    let supportFiles: [String: String]
    let credentialRequirements: [AgentSkillCredentialRequirement]

    var slug: String {
        AgentSkillMarketplaceStore.slug(from: skillName)
    }
}

enum AgentSkillMarketplaceStatus: Equatable {
    case available
    case installed
    case updateAvailable(installedVersion: String)
    case conflict

    var isInstalled: Bool {
        switch self {
        case .installed, .updateAvailable:
            return true
        case .available, .conflict:
            return false
        }
    }
}

enum AgentSkillMarketplaceError: LocalizedError {
    case invalidSkillName
    case conflictingUserSkill(String)
    case missingMarketplaceSkill(String)

    var errorDescription: String? {
        switch self {
        case .invalidSkillName:
            return L10n.Settings.Skill.marketplaceInvalidSkill
        case .conflictingUserSkill(let slug):
            return L10n.Settings.Skill.marketplaceConflict(slug)
        case .missingMarketplaceSkill(let slug):
            return L10n.Settings.Skill.marketplaceMissing(slug)
        }
    }
}

enum AgentSkillMarketplaceStore {
    static let markerPrefix = "willdeep-marketplace-id:"
    private static let versionPrefix = "willdeep-marketplace-version:"
    private static let credentialEnvPrefix = "willdeep-credential-env:"

    static func entries() -> [AgentSkillMarketplaceEntry] {
        [
            AgentSkillMarketplaceEntry(
                id: "ppt-story-architect",
                skillName: "ppt-story-architect",
                displayName: "PPT Story Architect",
                tagline: "Plan sharper decks before any slide is built.",
                detail: "Adds a strict deck brief, claim spine, slide intent map, visual direction, and QA checklist for presentation work.",
                version: "1.0.0",
                author: "WillDeep",
                category: "Presentation",
                tags: ["PPT", "Story", "Design QA"],
                minimumAppVersion: "1.60.0",
                skillDescription: "Use when creating or improving PPT decks that need stronger content structure, layout rhythm, and final QA.",
                skillBody: """
                # PPT Story Architect

                Use this skill before creating or editing a presentation deck.

                ## Workflow

                1. Write a deck brief: audience, decision context, desired takeaway, thesis, evidence available, and missing inputs.
                2. Write a claim spine: each slide gets a conclusion title, one proof object, and a reason it belongs.
                3. Build a slide intent map: open, prove, explain, compare, decide, pause, or appendix.
                4. Lock visual direction before slide authoring: editorial briefing, board analytics, product story, technical architecture, brand lookbook, sales narrative, or workshop teaching.
                5. Plan the contact sheet: vary macro layouts, avoid three repeated compositions, and ban default card grids.
                6. Render and inspect every slide before delivery.

                ## Quality Gates

                - No topic-label titles.
                - No decorative card grids around weak bullets.
                - No unsupported metrics or vague source labels.
                - No repeated layout rhythm without a narrative reason.
                - Every non-appendix slide needs a claim, proof object, and clear reading order.
                """,
                supportFiles: [:],
                credentialRequirements: []
            ),
            AgentSkillMarketplaceEntry(
                id: "pdf-design",
                skillName: "pdf-design",
                displayName: "PDF Design",
                tagline: "Create polished PDFs with page-system QA.",
                detail: "Guides PDF creation, conversion, export, and visual inspection so reports and handouts do not ship as ugly print dumps.",
                version: "1.0.0",
                author: "WillDeep",
                category: "Documents",
                tags: ["PDF", "Layout", "Visual QA"],
                minimumAppVersion: "1.60.0",
                skillDescription: "Use when creating, converting, redesigning, or QA-checking PDF deliverables with typography, page breaks, tables, images, headers, footers, and rendered-page inspection.",
                skillBody: """
                # PDF Design

                Use this skill for PDF deliverables where quality matters. A PDF is done only when the rendered pages look intentional, readable, and mechanically clean.

                ## Workflow

                1. Write a short PDF brief: audience, use case, source format, page size, orientation, margins, expected page count, reading task, and style direction.
                2. Define the page system: cover treatment, heading ladder, paragraph rhythm, header/footer/page numbers, table grammar, figure/caption/source-note rules, and page-break behavior.
                3. Build the source artifact with structured styles rather than one-off formatting.
                4. Export to PDF.
                5. Rasterize or screenshot every page.
                6. Inspect every page at readable size and thumbnail size.
                7. Fix the source and re-export until the rendered PDF passes.

                ## Source Choice

                - Use DOCX when the user needs Word-editable source or Google Docs import.
                - Use HTML/CSS when the PDF is a designed report, one-pager, form, catalog, dashboard export, or image-heavy handout.
                - Use LaTeX when math, academic citations, equations, or formal typesetting dominate.
                - Use deterministic PDF tools for merge, split, rotate, crop, compress, redact, or watermark operations.

                ## Quality Gates

                - No Markdown dump printed to PDF.
                - No long walls of text without headings, summaries, or visual anchors.
                - No inconsistent heading spacing, list indents, margins, headers, or footers.
                - No cramped tables, clipped text, orphan headings, detached captions, or broken page breaks.
                - No stretched, blurry, or poorly cropped images.
                - Text should remain selectable unless the user explicitly asks for image-only output.
                - Hyperlinks, bookmarks, and references must work when required.

                ## Delivery

                Return the final PDF and, when relevant, the editable source artifact. State whether rendered visual QA was completed.
                """,
                supportFiles: [:],
                credentialRequirements: []
            ),
            AgentSkillMarketplaceEntry(
                id: "image-processing",
                skillName: "image-processing",
                displayName: "Image Processing",
                tagline: "Crop, resize, convert, and clean raster images.",
                detail: "Adds deterministic PNG/JPEG/WebP/TIFF processing for crops, transparent backgrounds, alpha trimming, padding, flattening, and batch-safe asset prep.",
                version: "1.0.0",
                author: "WillDeep",
                category: "Media",
                tags: ["Image", "Crop", "Transparency"],
                minimumAppVersion: "1.60.0",
                skillDescription: "Use for deterministic raster image edits: crop, resize, format conversion, transparency, background removal by solid color, transparent-edge trimming, padding, flattening, and batch-safe asset preparation.",
                skillBody: """
                # Image Processing

                Use this skill for deterministic raster image edits. Prefer it over AI image generation when the request is mechanical: crop, resize, convert, trim, make a solid background transparent, flatten transparency, or prepare web/app assets.

                Use `$imagegen` only when the user wants a new generated image, inpainting, style transformation, or semantic object removal that cannot be achieved with deterministic pixel operations.

                ## Tool

                Use `scripts/process_image.py` for common operations:

                ```bash
                python3 scripts/process_image.py input.png output.png --trim-transparent
                python3 scripts/process_image.py input.jpg output.png --transparent-color "#ffffff" --tolerance 18
                python3 scripts/process_image.py input.png output.webp --max-size 1200x1200
                python3 scripts/process_image.py input.png output.png --crop 80,40,640,360
                python3 scripts/process_image.py input.png output.jpg --flatten-bg "#ffffff" --quality 92
                ```

                The script requires Pillow. If `import PIL` fails, resolve workspace Python dependencies first or explain the missing dependency.

                ## Workflow

                1. Inspect the source image dimensions and mode.
                2. Clarify only when the requested crop or transparent area is ambiguous.
                3. Preserve originals; write a new output file with a descriptive name.
                4. Run deterministic edits with `process_image.py`.
                5. Visually inspect the result before delivery.
                6. Report output path, dimensions, and format.

                ## Operations

                - Crop: use `--crop x,y,width,height` in source pixels.
                - Resize: use `--resize WIDTHxHEIGHT` for exact dimensions.
                - Fit within bounds: use `--max-size WIDTHxHEIGHT` to preserve aspect ratio.
                - Trim transparent border: use `--trim-transparent`.
                - Remove solid background: use `--transparent-color "#RRGGBB"` and tune `--tolerance`.
                - Flatten transparency: use `--flatten-bg "#RRGGBB"` for JPEG or required matte output.
                - Pad canvas: use `--pad left,top,right,bottom` and optional `--pad-color`.
                - Convert format: choose output extension or pass `--format png|jpeg|webp|tiff`.

                ## Quality Gates

                Do not stretch images unless explicitly requested. Preserve alpha when output format supports it. Do not save transparent output as JPEG. Check edges after background removal; halos mean tolerance or matte handling needs adjustment. Confirm final dimensions match the requested size.
                """,
                supportFiles: [
                    "scripts/process_image.py": #"""
                    #!/usr/bin/env python3
                    """Deterministic raster image processing helper."""

                    from __future__ import annotations

                    import argparse
                    import sys
                    from pathlib import Path

                    try:
                        from PIL import Image
                    except ImportError as exc:  # pragma: no cover - environment dependent
                        raise SystemExit("Pillow is required: python3 -m pip install Pillow") from exc


                    def parse_color(value: str) -> tuple[int, int, int, int]:
                        raw = value.strip()
                        if raw.startswith("#"):
                            raw = raw[1:]
                        if len(raw) not in (6, 8):
                            raise argparse.ArgumentTypeError("color must be #RRGGBB or #RRGGBBAA")
                        try:
                            parts = [int(raw[i : i + 2], 16) for i in range(0, len(raw), 2)]
                        except ValueError as exc:
                            raise argparse.ArgumentTypeError("invalid hex color") from exc
                        if len(parts) == 3:
                            parts.append(255)
                        return tuple(parts)  # type: ignore[return-value]


                    def parse_box(value: str) -> tuple[int, int, int, int]:
                        parts = value.split(",")
                        if len(parts) != 4:
                            raise argparse.ArgumentTypeError("expected x,y,width,height")
                        try:
                            x, y, width, height = [int(part.strip()) for part in parts]
                        except ValueError as exc:
                            raise argparse.ArgumentTypeError("box values must be integers") from exc
                        if width <= 0 or height <= 0:
                            raise argparse.ArgumentTypeError("width and height must be positive")
                        return x, y, width, height


                    def parse_padding(value: str) -> tuple[int, int, int, int]:
                        parts = value.split(",")
                        if len(parts) != 4:
                            raise argparse.ArgumentTypeError("expected left,top,right,bottom")
                        try:
                            left, top, right, bottom = [int(part.strip()) for part in parts]
                        except ValueError as exc:
                            raise argparse.ArgumentTypeError("padding values must be integers") from exc
                        if min(left, top, right, bottom) < 0:
                            raise argparse.ArgumentTypeError("padding values must be non-negative")
                        return left, top, right, bottom


                    def parse_size(value: str) -> tuple[int, int]:
                        normalized = value.lower().replace("×", "x")
                        parts = normalized.split("x")
                        if len(parts) != 2:
                            raise argparse.ArgumentTypeError("expected WIDTHxHEIGHT")
                        try:
                            width, height = [int(part.strip()) for part in parts]
                        except ValueError as exc:
                            raise argparse.ArgumentTypeError("size values must be integers") from exc
                        if width <= 0 or height <= 0:
                            raise argparse.ArgumentTypeError("width and height must be positive")
                        return width, height


                    def crop_image(image: Image.Image, crop: tuple[int, int, int, int]) -> Image.Image:
                        x, y, width, height = crop
                        return image.crop((x, y, x + width, y + height))


                    def trim_transparent(image: Image.Image) -> Image.Image:
                        rgba = image.convert("RGBA")
                        bbox = rgba.getchannel("A").getbbox()
                        if bbox is None:
                            return rgba
                        return rgba.crop(bbox)


                    def make_color_transparent(
                        image: Image.Image,
                        color: tuple[int, int, int, int],
                        tolerance: int,
                    ) -> Image.Image:
                        rgba = image.convert("RGBA")
                        pixels = rgba.load()
                        target_r, target_g, target_b, _ = color
                        width, height = rgba.size
                        for y in range(height):
                            for x in range(width):
                                r, g, b, a = pixels[x, y]
                                if (
                                    abs(r - target_r) <= tolerance
                                    and abs(g - target_g) <= tolerance
                                    and abs(b - target_b) <= tolerance
                                ):
                                    pixels[x, y] = (r, g, b, 0)
                                else:
                                    pixels[x, y] = (r, g, b, a)
                        return rgba


                    def add_padding(
                        image: Image.Image,
                        padding: tuple[int, int, int, int],
                        color: tuple[int, int, int, int],
                    ) -> Image.Image:
                        left, top, right, bottom = padding
                        base = Image.new("RGBA", (image.width + left + right, image.height + top + bottom), color)
                        base.alpha_composite(image.convert("RGBA"), (left, top))
                        return base


                    def flatten(image: Image.Image, background: tuple[int, int, int, int]) -> Image.Image:
                        rgba = image.convert("RGBA")
                        base = Image.new("RGBA", rgba.size, background)
                        base.alpha_composite(rgba)
                        return base.convert("RGB")


                    def output_format(path: Path, requested: str | None) -> str:
                        value = requested.lower() if requested else path.suffix.lower().lstrip(".")
                        aliases = {
                            "jpg": "jpeg",
                            "jpeg": "jpeg",
                            "png": "png",
                            "webp": "webp",
                            "tif": "tiff",
                            "tiff": "tiff",
                        }
                        if value not in aliases:
                            raise SystemExit(f"Unsupported output format: {value or '(none)'}")
                        return aliases[value]


                    def save_image(image: Image.Image, output: Path, fmt: str, quality: int) -> None:
                        output.parent.mkdir(parents=True, exist_ok=True)
                        save_kwargs = {}
                        if fmt in {"jpeg", "webp"}:
                            save_kwargs["quality"] = quality
                        if fmt == "jpeg" and image.mode in {"RGBA", "LA", "P"}:
                            image = flatten(image, (255, 255, 255, 255))
                        image.save(output, format=fmt.upper() if fmt != "jpeg" else "JPEG", **save_kwargs)


                    def main(argv: list[str]) -> int:
                        parser = argparse.ArgumentParser(description=__doc__)
                        parser.add_argument("input", type=Path)
                        parser.add_argument("output", type=Path)
                        parser.add_argument("--crop", type=parse_box, help="Crop box as x,y,width,height")
                        parser.add_argument("--resize", type=parse_size, help="Exact resize as WIDTHxHEIGHT")
                        parser.add_argument("--max-size", type=parse_size, help="Fit within WIDTHxHEIGHT, preserving aspect ratio")
                        parser.add_argument("--trim-transparent", action="store_true", help="Trim transparent border")
                        parser.add_argument("--transparent-color", type=parse_color, help="Make matching solid color transparent")
                        parser.add_argument("--tolerance", type=int, default=10, help="Color tolerance for --transparent-color")
                        parser.add_argument("--flatten-bg", type=parse_color, help="Flatten transparency onto #RRGGBB")
                        parser.add_argument("--pad", type=parse_padding, help="Pad canvas by left,top,right,bottom")
                        parser.add_argument("--pad-color", type=parse_color, default=(0, 0, 0, 0), help="Padding color")
                        parser.add_argument("--format", choices=["png", "jpeg", "jpg", "webp", "tiff", "tif"])
                        parser.add_argument("--quality", type=int, default=92)
                        args = parser.parse_args(argv)

                        if args.tolerance < 0 or args.tolerance > 255:
                            raise SystemExit("--tolerance must be between 0 and 255")
                        if args.quality < 1 or args.quality > 100:
                            raise SystemExit("--quality must be between 1 and 100")

                        image = Image.open(args.input)
                        if args.crop:
                            image = crop_image(image, args.crop)
                        if args.transparent_color:
                            image = make_color_transparent(image, args.transparent_color, args.tolerance)
                        if args.trim_transparent:
                            image = trim_transparent(image)
                        if args.resize:
                            image = image.resize(args.resize, Image.Resampling.LANCZOS)
                        if args.max_size:
                            image = image.copy()
                            image.thumbnail(args.max_size, Image.Resampling.LANCZOS)
                        if args.pad:
                            image = add_padding(image, args.pad, args.pad_color)
                        if args.flatten_bg:
                            image = flatten(image, args.flatten_bg)

                        fmt = output_format(args.output, args.format)
                        if fmt == "jpeg" and image.mode in {"RGBA", "LA"} and not args.flatten_bg:
                            print("warning: JPEG does not support alpha; flattening on white", file=sys.stderr)
                        save_image(image, args.output, fmt, args.quality)
                        print(f"{args.output} {image.width}x{image.height} {fmt}")
                        return 0


                    if __name__ == "__main__":
                        raise SystemExit(main(sys.argv[1:]))
                    """#
                ],
                credentialRequirements: []
            ),
            AgentSkillMarketplaceEntry(
                id: "release-guardian",
                skillName: "release-guardian",
                displayName: "Release Guardian",
                tagline: "Check version, changelog, tests, and release notes together.",
                detail: "Guides release prep with semantic version checks, changelog updates, product overview sync, and verification notes.",
                version: "1.0.0",
                author: "WillDeep",
                category: "Engineering",
                tags: ["Release", "Changelog", "Version"],
                minimumAppVersion: "1.60.0",
                skillDescription: "Use when preparing, reviewing, or shipping a release that needs version, changelog, docs, and verification discipline.",
                skillBody: """
                # Release Guardian

                Use this skill when preparing or reviewing a release.

                ## Checklist

                1. Identify whether the change is a feature, bugfix, documentation change, or internal refactor.
                2. Confirm the version bump follows project rules.
                3. Update changelog and product overview when behavior or version changes.
                4. Verify frontend and backend versions stay aligned when both exist.
                5. Run the narrowest meaningful tests first, then broaden if the changed surface is shared.
                6. Summarize remaining risk plainly.

                ## Output

                Return release readiness as: ready, needs fix, or blocked. Include changed files, tests run, and unresolved risks.
                """,
                supportFiles: [:],
                credentialRequirements: []
            ),
            AgentSkillMarketplaceEntry(
                id: "static-site-publisher",
                skillName: "static-site-publisher",
                displayName: "Static Site Publisher",
                tagline: "Find, build, and publish static frontends conservatively.",
                detail: "Provider-neutral workflow for identifying deployable build outputs, running safe builds, and handing off preview URLs.",
                version: "1.0.0",
                author: "WillDeep",
                category: "Deployment",
                tags: ["Static Site", "Build", "Deploy"],
                minimumAppVersion: "1.91.0",
                skillDescription: "Use when preparing, previewing, or publishing a static frontend build directory such as dist, build, out, public, _site, or docs; also use when a user asks for a shareable preview URL and the project may be a static site.",
                skillBody: """
                # Static Site Publisher

                Use this skill when the user wants to deploy, preview, publish, or share a static frontend.

                ## Workflow

                1. Identify the target directory. If the user named one, verify it exists and contains `index.html`.
                2. If no target is named, check only common build output directories: `dist`, `build`, `out`, `output`, `public`, `.next/out`, `.output/public`, `_site`, `www`, and `docs`.
                3. If exactly one deployable directory is found, use it. If multiple are found, ask the user to choose.
                4. If none is found, inspect `package.json` for a standard static build script: `build`, `build:prod`, `build:production`, `generate`, or `export`.
                5. Prefer the package manager implied by the lockfile. If dependencies are missing, ask before installing them.
                6. Run the build script only when it is explicit. Do not invent build commands.
                7. Re-scan the allowlisted output directories after a successful build.
                8. Serve or deploy the chosen directory through the available local or remote publishing mechanism.

                ## Guardrails

                - Static assets only. Stop if the app requires SSR, a backend process, a database, or runtime secrets.
                - Do not recursively scan the whole repository looking for random `index.html` files.
                - Do not upload `.env`, private keys, database dumps, source maps with secrets, or build caches.
                - If the deployment target is unclear, report the candidate directories and ask for one decision.

                ## Handoff

                Tell the user the chosen directory, build command used, preview/deploy URL if available, and any limitation that prevented publishing.
                """,
                supportFiles: [:],
                credentialRequirements: []
            ),
            AgentSkillMarketplaceEntry(
                id: "feishu-ops-playbook",
                skillName: "feishu-ops-playbook",
                displayName: "Feishu Ops Playbook",
                tagline: "Operate Feishu docs, messages, sheets, and apps with less guesswork.",
                detail: "A WillDeep-native Feishu/Lark operating guide focused on setup checks, identity choice, schema inspection, and safe collaboration actions.",
                version: "1.0.0",
                author: "WillDeep",
                category: "Collaboration",
                tags: ["Feishu", "Lark", "Docs"],
                minimumAppVersion: "1.91.0",
                skillDescription: "Use when working with Feishu or Lark messages, documents, sheets, calendars, tasks, wiki spaces, files, bot events, or app setup; also use when choosing between WillDeep connectors, lark-cli, or manual Feishu open-platform configuration.",
                skillBody: """
                # Feishu Ops Playbook

                Use this skill for Feishu/Lark collaboration work: messages, docs, sheets, files, wiki, tasks, calendars, bot events, and app setup.

                ## Setup Order

                1. Prefer an already configured WillDeep connector or MCP tool when one is available.
                2. If using a CLI, first check whether it is installed and configured; do not start an interactive setup command that requires a TTY unless the user is ready to scan or authorize.
                3. Keep secrets out of prompts, command arguments, and logs. Store app secrets, webhook tokens, and user tokens in Keychain or `.env` files that are ignored by git.
                4. For self-built apps, record the App ID, enabled capabilities, permission scopes, event transport mode, and callback/long-connection choice.

                ## Identity Choice

                - Use bot identity for group messages, event handling, app-owned docs, and automation.
                - Use user identity only when the operation must happen as the user, such as personal drive files or calendar access.
                - Before write actions, confirm the target chat, document, sheet, base, or wiki space.

                ## API Work

                1. Inspect the target API schema or CLI help before calling low-level commands.
                2. Prefer high-level shortcuts for common operations; use raw APIs only when the shortcut does not cover the task.
                3. Treat IDs carefully: `chat_id`, `message_id`, `document_id`, `file_token`, `spreadsheet_token`, `sheet_id`, `base_id`, `table_id`, and `event_id` are not interchangeable.
                4. Paginate list/search calls and summarize results before mutating anything.

                ## Common Tasks

                - Send a message: identify chat, choose text/card/file format, send as bot unless user identity is required.
                - Create a doc: create the document, write structured content, set permissions, and return the share link.
                - Work with sheets: read headers first, map columns by name, append/update rows, then verify the affected range.
                - Configure bot events: choose callback or long connection, subscribe only required events, test with a small message, and expose health status.

                ## Safety

                Never invent successful Feishu URLs. If an API call fails, report the error code, permission hint, and exact next setup step.
                """,
                supportFiles: [:],
                credentialRequirements: []
            ),
            AgentSkillMarketplaceEntry(
                id: "fullstack-delivery-guard",
                skillName: "fullstack-delivery-guard",
                displayName: "Fullstack Delivery Guard",
                tagline: "Ship backend plus frontend work with contracts, tests, and handoff.",
                detail: "A compact delivery guard for APIs, frontends, auth, realtime, config, and production hardening.",
                version: "1.0.0",
                author: "WillDeep",
                category: "Engineering",
                tags: ["Fullstack", "API", "Testing"],
                minimumAppVersion: "1.91.0",
                skillDescription: "Use when building or reviewing a full-stack app, REST API plus frontend integration, backend service, CRUD workflow, auth flow, file upload, realtime feature, service layer, API client, configuration, or production hardening.",
                skillBody: """
                # Fullstack Delivery Guard

                Use this skill when a task crosses the frontend/backend boundary.

                ## Before Coding

                Decide or infer:

                1. Service shape: API-only, monolith, or separated frontend/backend.
                2. Backend stack and frontend stack.
                3. Data store and migration strategy.
                4. API style: REST, GraphQL, tRPC, gRPC, or simple server actions.
                5. Auth: none, session, JWT plus refresh, OAuth, or hosted auth.
                6. Realtime: none, polling, SSE, or WebSocket.

                State these decisions briefly before large edits.

                ## Architecture Rules

                - Organize by feature when the app has multiple domains.
                - Controllers/handlers parse, validate, and call services; they do not hold business logic.
                - Services do not import HTTP request/response types.
                - Repositories or data clients hide SQL/API details from services.
                - Validate all input at the boundary.
                - Centralize config and fail fast when required env vars are missing.
                - Use structured errors and a consistent API error shape.
                - Add request IDs and structured logs for server code.

                ## Frontend Integration

                - Keep API base URLs in env/config, not hardcoded source.
                - Use a typed client, OpenAPI-generated client, tRPC, or a small fetch wrapper with consistent errors.
                - Handle loading, empty, and error states on every user-visible async path.
                - Keep auth tokens out of localStorage when the app needs strong security; prefer httpOnly refresh cookies.

                ## Verification

                Run the narrowest meaningful checks:

                1. Backend build/test.
                2. Frontend build/test.
                3. Smoke a health endpoint.
                4. Smoke one happy-path API plus the UI path that consumes it.
                5. For realtime, verify behavior in two clients.

                ## Handoff

                Summarize endpoints, key files, run commands, env vars, tests run, and known gaps.
                """,
                supportFiles: [:],
                credentialRequirements: []
            ),
            AgentSkillMarketplaceEntry(
                id: "mcp-builder",
                skillName: "mcp-builder",
                displayName: "MCP Builder",
                tagline: "Design MCP servers that agents can actually use.",
                detail: "A compact MCP server construction guide adapted for WillDeep: tool naming, schemas, transport choice, auth, pagination, error messages, and evaluation questions.",
                version: "1.0.0",
                author: "WillDeep",
                category: "Integration",
                tags: ["MCP", "Tools", "API"],
                minimumAppVersion: "1.91.0",
                skillDescription: "Use when building, reviewing, or planning an MCP server for an external API or internal service, including Python FastMCP, TypeScript MCP SDK, stdio servers, streamable HTTP servers, tool schemas, resources, prompts, auth, and evaluations.",
                skillBody: """
                # MCP Builder

                Use this skill when creating or reviewing an MCP server.

                ## Design First

                1. Read the target service's API docs and authentication model.
                2. Choose transport:
                   - `stdio` for local developer tools.
                   - Streamable HTTP for remote/team services.
                3. Choose language:
                   - TypeScript when SDK compatibility and schema ergonomics matter most.
                   - Python/FastMCP when the service ecosystem or existing scripts are Python-first.
                4. Decide whether to expose workflow tools, endpoint-shaped tools, or both.

                ## Tool Design

                - Use action-oriented names with a consistent prefix, such as `github_list_issues` or `feishu_create_doc`.
                - Keep descriptions concise but explicit about side effects.
                - Use structured input schemas with constraints and examples.
                - Return focused data. Paginate or filter large result sets.
                - Include annotations: read-only, destructive, idempotent, and open-world hints when supported.
                - Error messages must say what failed, why it likely failed, and what the agent should try next.

                ## Security

                - Never hardcode tokens.
                - Support env vars or a credential store.
                - Mask secrets in logs and tool results.
                - Separate read tools from write/destructive tools.
                - For user-scoped APIs, make the acting identity visible in tool output.

                ## Implementation Checklist

                1. Shared API client with auth, timeout, retry, and pagination helpers.
                2. Tool modules grouped by domain.
                3. Consistent response formatting with both human-readable text and structured content when available.
                4. Unit tests for schema validation and client error handling.
                5. Inspector smoke test or equivalent local MCP client test.

                ## Evaluations

                Create 5 to 10 realistic read-only questions that require multiple tool calls. Each answer should be stable, independently verifiable, and not dependent on time-sensitive live data unless the test fixture freezes it.
                """,
                supportFiles: [:],
                credentialRequirements: []
            ),
            AgentSkillMarketplaceEntry(
                id: "swiftui-polish-review",
                skillName: "swiftui-polish-review",
                displayName: "SwiftUI Polish Review",
                tagline: "Review macOS SwiftUI screens for layout, state, and fit.",
                detail: "Focuses UI review on text fit, density, AppKit bridging, state ownership, accessibility, and regressions.",
                version: "1.0.0",
                author: "WillDeep",
                category: "macOS",
                tags: ["SwiftUI", "macOS", "Review"],
                minimumAppVersion: "1.60.0",
                skillDescription: "Use when reviewing or improving a SwiftUI/AppKit macOS interface for layout polish, state flow, and usability.",
                skillBody: """
                # SwiftUI Polish Review

                Use this skill for SwiftUI or AppKit-backed macOS UI changes.

                ## Review Focus

                - Text must fit in compact and wide window sizes.
                - Controls should match macOS expectations and avoid custom chrome unless needed.
                - State should have one owner; derived UI should not persist stale copies.
                - Long lists need filtering, grouping, and predictable empty states.
                - AppKit bridges must avoid publishing state during view updates.
                - Settings screens should save immediately or clearly show when changes apply.

                ## Verification

                Inspect the screen at minimum useful width, normal width, and a large window. Check hover states, disabled states, empty states, and error messages.
                """,
                supportFiles: [:],
                credentialRequirements: []
            )
        ]
    }

    static func status(
        for entry: AgentSkillMarketplaceEntry,
        root: URL = AgentSkillFileManager.userSkillsRoot
    ) -> AgentSkillMarketplaceStatus {
        let skillURL = installedSkillURL(for: entry, root: root)
        guard FileManager.default.fileExists(atPath: skillURL.path),
              let text = try? String(contentsOf: skillURL, encoding: .utf8) else {
            return .available
        }
        guard marketplaceID(in: text) == entry.id else {
            return .conflict
        }
        let installedVersion = marketplaceVersion(in: text)
        if installedVersion == entry.version {
            return .installed
        }
        return .updateAvailable(installedVersion: installedVersion.isEmpty ? "unknown" : installedVersion)
    }

    static func install(
        _ entry: AgentSkillMarketplaceEntry,
        credentials: [String: String] = [:],
        root: URL = AgentSkillFileManager.userSkillsRoot
    ) throws -> URL {
        guard !entry.slug.isEmpty else {
            throw AgentSkillMarketplaceError.invalidSkillName
        }

        let skillDirectory = root.appendingPathComponent(entry.slug)
        let skillURL = skillDirectory.appendingPathComponent("SKILL.md")
        if FileManager.default.fileExists(atPath: skillURL.path),
           let text = try? String(contentsOf: skillURL, encoding: .utf8),
           marketplaceID(in: text) != entry.id {
            throw AgentSkillMarketplaceError.conflictingUserSkill(entry.slug)
        }

        try FileManager.default.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
        storeCredentials(credentials, for: entry)
        try skillMarkdown(for: entry).write(to: skillURL, atomically: true, encoding: .utf8)
        AgentSkillDirectory.invalidateCache()
        for (relativePath, contents) in entry.supportFiles {
            let supportURL = skillDirectory.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: supportURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try contents.write(to: supportURL, atomically: true, encoding: .utf8)
        }
        return skillURL
    }

    static func uninstall(
        _ entry: AgentSkillMarketplaceEntry,
        root: URL = AgentSkillFileManager.userSkillsRoot
    ) throws {
        let skillURL = installedSkillURL(for: entry, root: root)
        guard FileManager.default.fileExists(atPath: skillURL.path),
              let text = try? String(contentsOf: skillURL, encoding: .utf8),
              marketplaceID(in: text) == entry.id else {
            throw AgentSkillMarketplaceError.missingMarketplaceSkill(entry.slug)
        }
        clearCredentials(for: entry)
        try FileManager.default.removeItem(at: skillURL.deletingLastPathComponent())
        AgentSkillDirectory.invalidateCache()
    }

    static func installedSkillURL(
        for entry: AgentSkillMarketplaceEntry,
        root: URL = AgentSkillFileManager.userSkillsRoot
    ) -> URL {
        root.appendingPathComponent(entry.slug)
            .appendingPathComponent("SKILL.md")
    }

    static func slug(from name: String) -> String {
        let lowercased = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var slug = ""
        var previousWasDash = false
        for scalar in lowercased.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                slug.unicodeScalars.append(scalar)
                previousWasDash = false
            } else if !previousWasDash {
                slug.append("-")
                previousWasDash = true
            }
        }
        return slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    static func credentialAccount(for entry: AgentSkillMarketplaceEntry, requirement: AgentSkillCredentialRequirement) -> String {
        AgentCredentialStore.skillAccount(entryID: entry.id, credentialID: requirement.id)
    }

    static func credentialReference(for entry: AgentSkillMarketplaceEntry, requirement: AgentSkillCredentialRequirement) -> String {
        AgentCredentialStore.reference(account: credentialAccount(for: entry, requirement: requirement))
    }

    static func isCredentialConfigured(for entry: AgentSkillMarketplaceEntry, requirement: AgentSkillCredentialRequirement) -> Bool {
        !AgentCredentialStore.load(account: credentialAccount(for: entry, requirement: requirement)).isEmpty
    }

    static func areRequiredCredentialsConfigured(for entry: AgentSkillMarketplaceEntry) -> Bool {
        entry.credentialRequirements.allSatisfy {
            !$0.isRequired || isCredentialConfigured(for: entry, requirement: $0)
        }
    }

    static func storeCredentials(_ credentials: [String: String], for entry: AgentSkillMarketplaceEntry) {
        for requirement in entry.credentialRequirements {
            guard let value = credentials[requirement.id],
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            AgentCredentialStore.save(
                value,
                account: credentialAccount(for: entry, requirement: requirement)
            )
        }
    }

    static func clearCredentials(for entry: AgentSkillMarketplaceEntry) {
        for requirement in entry.credentialRequirements {
            AgentCredentialStore.delete(account: credentialAccount(for: entry, requirement: requirement))
        }
    }

    private static func skillMarkdown(for entry: AgentSkillMarketplaceEntry) -> String {
        var metadataLines = [
            "name: \(entry.skillName)",
            "description: \(entry.skillDescription)",
            "\(markerPrefix) \(entry.id)",
            "\(versionPrefix) \(entry.version)"
        ]
        metadataLines.append(contentsOf: entry.credentialRequirements.map { requirement in
            "\(credentialEnvPrefix) \(requirement.environmentVariable)=\(credentialReference(for: entry, requirement: requirement))"
        })
        return """
        ---
        \(metadataLines.joined(separator: "\n"))
        ---

        \(entry.skillBody.trimmingCharacters(in: .whitespacesAndNewlines))
        """
    }

    private static func marketplaceID(in text: String) -> String {
        metadataValue(in: text, prefix: markerPrefix)
    }

    private static func marketplaceVersion(in text: String) -> String {
        metadataValue(in: text, prefix: versionPrefix)
    }

    private static func metadataValue(in text: String, prefix: String) -> String {
        for line in text.components(separatedBy: .newlines) {
            guard line.hasPrefix(prefix) else { continue }
            return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }
}
