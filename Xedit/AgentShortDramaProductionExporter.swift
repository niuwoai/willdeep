//
//  AgentShortDramaProductionExporter.swift
//  WillDeep
//
//  Short-drama production package export, Ruby handoff template,
//  media manifest template, and widget preview HTML generation.
//

import Foundation

enum AgentShortDramaProductionExporter {
    struct ExportResult {
        var directory: URL
        var jsonURL: URL
        var markdownURL: URL
        var mediaManifestTemplateURL: URL
        var rubyScriptTemplateURL: URL
        var envExampleURL: URL
        var widgetPreviewURL: URL
        var timelineURL: URL
        var gapReportURL: URL
        var shotListCSVURL: URL
        var reviewTemplateCSVURL: URL
        var reviewQueueCSVURL: URL
        var outputDirectory: URL
    }

    struct Package: Codable {
        var exportedAt: Date
        var scope: String
        var project: AgentShortDramaProject
        var openReviewItemCount: Int
        var selectedArtifactCount: Int
        var artifactCount: Int
    }

    struct Timeline: Codable {
        var exportedAt: Date
        var scope: String
        var projectID: String
        var projectTitle: String
        var logline: String?
        var episodes: [Episode]

        enum CodingKeys: String, CodingKey {
            case exportedAt = "exported_at"
            case scope
            case projectID = "project_id"
            case projectTitle = "project_title"
            case logline
            case episodes
        }

        struct Episode: Codable {
            var id: String
            var order: Int
            var title: String
            var summary: String?
            var shots: [Shot]
        }

        struct Shot: Codable {
            var id: String
            var order: Int
            var title: String
            var status: String
            var summary: String?
            var prompt: String?
            var selectedImagePath: String?
            var videoPaths: [String]
            var imagePaths: [String]
            var artifactPaths: [String]
            var openReviewItemCount: Int

            enum CodingKeys: String, CodingKey {
                case id
                case order
                case title
                case status
                case summary
                case prompt
                case selectedImagePath = "selected_image_path"
                case videoPaths = "video_paths"
                case imagePaths = "image_paths"
                case artifactPaths = "artifact_paths"
                case openReviewItemCount = "open_review_item_count"
            }
        }
    }

    struct GapReport: Codable {
        var exportedAt: Date
        var scope: String
        var projectID: String
        var projectTitle: String
        var missingImageCount: Int
        var missingVideoCount: Int
        var missingAssetReferenceCount: Int
        var openReviewItemCount: Int
        var episodes: [Episode]
        var assets: [Asset]
        var batchActions: BatchActions

        enum CodingKeys: String, CodingKey {
            case exportedAt = "exported_at"
            case scope
            case projectID = "project_id"
            case projectTitle = "project_title"
            case missingImageCount = "missing_image_count"
            case missingVideoCount = "missing_video_count"
            case missingAssetReferenceCount = "missing_asset_reference_count"
            case openReviewItemCount = "open_review_item_count"
            case episodes
            case assets
            case batchActions = "batch_actions"
        }

        struct Episode: Codable {
            var id: String
            var order: Int
            var title: String
            var missingImageCount: Int
            var missingVideoCount: Int
            var openReviewItemCount: Int
            var shots: [Shot]

            enum CodingKeys: String, CodingKey {
                case id
                case order
                case title
                case missingImageCount = "missing_image_count"
                case missingVideoCount = "missing_video_count"
                case openReviewItemCount = "open_review_item_count"
                case shots
            }
        }

        struct Shot: Codable {
            var id: String
            var order: Int
            var title: String
            var status: String
            var missingImage: Bool
            var missingVideo: Bool
            var openReviewItemCount: Int
            var selectedImagePath: String?
            var videoPaths: [String]
            var imageDryRunArguments: String?
            var imageSubmitArguments: String?
            var videoDryRunArguments: String?
            var videoSubmitArguments: String?
            var reviewTasksArguments: String?

            enum CodingKeys: String, CodingKey {
                case id
                case order
                case title
                case status
                case missingImage = "missing_image"
                case missingVideo = "missing_video"
                case openReviewItemCount = "open_review_item_count"
                case selectedImagePath = "selected_image_path"
                case videoPaths = "video_paths"
                case imageDryRunArguments = "image_dry_run_arguments"
                case imageSubmitArguments = "image_submit_arguments"
                case videoDryRunArguments = "video_dry_run_arguments"
                case videoSubmitArguments = "video_submit_arguments"
                case reviewTasksArguments = "review_tasks_arguments"
            }
        }

        struct Asset: Codable {
            var id: String
            var kind: String
            var name: String
            var referenceImageCount: Int
            var missingReference: Bool
            var linkedShotCount: Int
            var linkedShotIDs: [String]
            var openTasksArguments: String
            var refreshTasksArguments: String
            var generateReferenceDryRunArguments: String?
            var generateReferenceArguments: String?
            var linkedShotImageDryRunArguments: String?
            var linkedShotImageSubmitArguments: String?
            var linkedShotVideoDryRunArguments: String?
            var linkedShotVideoSubmitArguments: String?

            enum CodingKeys: String, CodingKey {
                case id
                case kind
                case name
                case referenceImageCount = "reference_image_count"
                case missingReference = "missing_reference"
                case linkedShotCount = "linked_shot_count"
                case linkedShotIDs = "linked_shot_ids"
                case openTasksArguments = "open_tasks_arguments"
                case refreshTasksArguments = "refresh_tasks_arguments"
                case generateReferenceDryRunArguments = "generate_reference_dry_run_arguments"
                case generateReferenceArguments = "generate_reference_arguments"
                case linkedShotImageDryRunArguments = "linked_shot_image_dry_run_arguments"
                case linkedShotImageSubmitArguments = "linked_shot_image_submit_arguments"
                case linkedShotVideoDryRunArguments = "linked_shot_video_dry_run_arguments"
                case linkedShotVideoSubmitArguments = "linked_shot_video_submit_arguments"
            }
        }

        struct BatchActions: Codable {
            var imageDryRunArguments: String
            var imageSubmitArguments: String
            var videoDryRunArguments: String
            var videoSubmitArguments: String

            enum CodingKeys: String, CodingKey {
                case imageDryRunArguments = "image_dry_run_arguments"
                case imageSubmitArguments = "image_submit_arguments"
                case videoDryRunArguments = "video_dry_run_arguments"
                case videoSubmitArguments = "video_submit_arguments"
            }
        }
    }

    struct MediaImportManifestTemplate: Codable {
        var title: String
        var baseDirectory: String
        var provider: String
        var projectID: String
        var items: [Item]

        enum CodingKeys: String, CodingKey {
            case title
            case baseDirectory = "base_directory"
            case provider
            case projectID = "project_id"
            case items
        }

        struct Item: Codable {
            var filePath: String
            var title: String
            var taskTitle: String
            var kind: String
            var prompt: String?
            var model: String?
            var statusEndpointSuffix: String?
            var cancelEndpointSuffix: String?
            var sourceImagePath: String? = ""
            var maskPath: String? = ""
            var projectID: String
            var episodeID: String?
            var shotID: String?
            var assetKind: String?
            var assetID: String?
            var reviewItemID: String? = nil
            var suggestedAction: String? = nil

            enum CodingKeys: String, CodingKey {
                case filePath = "file_path"
                case title
                case taskTitle = "task_title"
                case kind
                case prompt
                case model
                case statusEndpointSuffix = "status_endpoint_suffix"
                case cancelEndpointSuffix = "cancel_endpoint_suffix"
                case sourceImagePath = "source_image_path"
                case maskPath = "mask_path"
                case projectID = "project_id"
                case episodeID = "episode_id"
                case shotID = "shot_id"
                case assetKind = "asset_kind"
                case assetID = "asset_id"
                case reviewItemID = "review_item_id"
                case suggestedAction = "suggested_action"
            }
        }
    }

    static func export(
        project: AgentShortDramaProject,
        episodeID: UUID? = nil,
        includeResolvedReviewItems: Bool = false
    ) throws -> ExportResult {
        let scopedProject = scoped(project: project, episodeID: episodeID, includeResolvedReviewItems: includeResolvedReviewItems)
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let directory = base
            .appendingPathComponent("WillDeep/short-drama/exports", isDirectory: true)
            .appendingPathComponent(exportDirectoryName(project: scopedProject, episodeID: episodeID), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let outputDirectory = directory.appendingPathComponent("outputs", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let package = Package(
            exportedAt: Date(),
            scope: episodeID == nil ? "project" : "episode",
            project: scopedProject,
            openReviewItemCount: openReviewItemCount(in: scopedProject),
            selectedArtifactCount: selectedArtifactCount(in: scopedProject),
            artifactCount: artifactCount(in: scopedProject)
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let jsonURL = directory.appendingPathComponent("production-package.json", isDirectory: false)
        try encoder.encode(package).write(to: jsonURL, options: [.atomic])

        let markdownURL = directory.appendingPathComponent("production-package.md", isDirectory: false)
        try markdown(for: package, directory: directory, includeResolvedReviewItems: includeResolvedReviewItems)
            .data(using: .utf8)?
            .write(to: markdownURL, options: [.atomic])

        let timelineURL = directory.appendingPathComponent("production-timeline.json", isDirectory: false)
        try encoder.encode(timeline(for: package)).write(to: timelineURL, options: [.atomic])

        let gapReportURL = directory.appendingPathComponent("production-gap-report.json", isDirectory: false)
        try encoder.encode(gapReport(for: package)).write(to: gapReportURL, options: [.atomic])

        let shotListCSVURL = directory.appendingPathComponent("production-shot-list.csv", isDirectory: false)
        try shotListCSV(for: package)
            .data(using: .utf8)?
            .write(to: shotListCSVURL, options: [.atomic])

        let reviewTemplateCSVURL = directory.appendingPathComponent("production-review-template.csv", isDirectory: false)
        try reviewTemplateCSV(for: package)
            .data(using: .utf8)?
            .write(to: reviewTemplateCSVURL, options: [.atomic])

        let reviewQueueCSVURL = directory.appendingPathComponent("production-review-queue.csv", isDirectory: false)
        try reviewQueueCSV(for: package)
            .data(using: .utf8)?
            .write(to: reviewQueueCSVURL, options: [.atomic])

        let manifestTemplateURL = directory.appendingPathComponent("media-import-manifest-template.json", isDirectory: false)
        try encoder.encode(mediaImportManifestTemplate(for: scopedProject)).write(to: manifestTemplateURL, options: [.atomic])

        let rubyScriptTemplateURL = directory.appendingPathComponent("ruby-media-script-template.rb", isDirectory: false)
        try rubyMediaScriptTemplate()
            .data(using: .utf8)?
            .write(to: rubyScriptTemplateURL, options: [.atomic])

        let envExampleURL = directory.appendingPathComponent("media-api.env.example", isDirectory: false)
        try mediaAPIEnvExampleTemplate()
            .data(using: .utf8)?
            .write(to: envExampleURL, options: [.atomic])

        let widgetPreviewURL = directory.appendingPathComponent("widget-preview.html", isDirectory: false)
        try widgetPreviewHTML(for: package, directory: directory, generated: [], skipped: [])
            .data(using: .utf8)?
            .write(to: widgetPreviewURL, options: [.atomic])

        return ExportResult(
            directory: directory,
            jsonURL: jsonURL,
            markdownURL: markdownURL,
            mediaManifestTemplateURL: manifestTemplateURL,
            rubyScriptTemplateURL: rubyScriptTemplateURL,
            envExampleURL: envExampleURL,
            widgetPreviewURL: widgetPreviewURL,
            timelineURL: timelineURL,
            gapReportURL: gapReportURL,
            shotListCSVURL: shotListCSVURL,
            reviewTemplateCSVURL: reviewTemplateCSVURL,
            reviewQueueCSVURL: reviewQueueCSVURL,
            outputDirectory: outputDirectory
        )
    }

    private static func scoped(
        project: AgentShortDramaProject,
        episodeID: UUID?,
        includeResolvedReviewItems: Bool
    ) -> AgentShortDramaProject {
        var copy = project
        if let episodeID {
            copy.episodes = copy.episodes.filter { $0.id == episodeID }
            let scopedShots = copy.episodes.flatMap(\.shots)
            let sceneIDs = Set(scopedShots.compactMap(\.sceneID))
            let characterIDs = Set(scopedShots.flatMap(\.characterIDs))
            copy.scenes = copy.scenes.filter { sceneIDs.contains($0.id) }
            copy.characters = copy.characters.filter { characterIDs.contains($0.id) }
        }
        guard !includeResolvedReviewItems else { return copy }
        copy.episodes = copy.episodes.map { episode in
            var nextEpisode = episode
            nextEpisode.shots = nextEpisode.shots.map { shot in
                var nextShot = shot
                nextShot.reviewItems = nextShot.reviewItems.filter { $0.status != .resolved }
                return nextShot
            }
            return nextEpisode
        }
        return copy
    }

    private static func markdown(for package: Package, directory: URL, includeResolvedReviewItems: Bool) -> String {
        let handoff = productionPackageHandoffMarkdown(directory: directory)
        var lines: [String] = [
            "# \(package.project.title)",
            "",
            "- Exported at: \(ISO8601DateFormatter().string(from: package.exportedAt))",
            "- Scope: \(package.scope)",
            "- Project id: \(package.project.id.uuidString)",
            "- Episodes: \(package.project.episodes.count)",
            "- Shots: \(package.project.episodes.reduce(0) { $0 + $1.shots.count })",
            "- Artifacts: \(package.artifactCount)",
            "- Selected artifacts: \(package.selectedArtifactCount)",
            "- Open review items: \(package.openReviewItemCount)",
            "- Production timeline: `production-timeline.json`",
            "- Production gap report: `production-gap-report.json`",
            "- Production shot list CSV: `production-shot-list.csv`",
            "- Review import template CSV: `production-review-template.csv`",
            "- Review fix queue CSV: `production-review-queue.csv`",
            "- Media import manifest template: `media-import-manifest-template.json`",
            "- Ruby script template: `ruby-media-script-template.rb`",
            "- Media API env example: `media-api.env.example`",
            "- Widget preview HTML: `widget-preview.html`",
            "- Script output directory: `outputs/`",
            "",
            "## Script Handoff",
            "",
            "1. Edit `ruby-media-script-template.rb` or replace it with your own Ruby/Skill script.",
            "2. Copy `media-api.env.example` outside the package or source it locally, then fill credentials in environment variables; do not write API keys into this package.",
            "3. Write generated images/videos into `outputs/` using the `file_path` values from `media-import-manifest-template.json`.",
            "",
            "Paste this handoff block back into WillDeep Agent when you want the chat window to continue from this package without guessing paths:",
            "",
            "```text",
            handoff,
            "```",
            "",
            "Optional environment variables supported by the Ruby template:",
            "",
            "- `WILLDEEP_MEDIA_API_URL`: media API submit endpoint.",
            "- `WILLDEEP_MEDIA_API_TOKEN`: bearer token for submit and poll requests.",
            "- `WILLDEEP_MEDIA_API_METHOD`: submit HTTP method, default `POST`.",
            "- `WILLDEEP_MEDIA_EXTRA_HEADERS_JSON`: optional JSON object of extra headers, such as `{\\\"X-API-Key\\\":\\\"...\\\"}`; keep secrets in a private env file.",
            "- `WILLDEEP_MEDIA_REQUEST_FORMAT`: `json` by default, or `multipart` for providers that require file uploads.",
            "- `WILLDEEP_MEDIA_REQUEST_PRESET`: optional request body preset; use `replicate_predictions` for Replicate `/v1/predictions` so body becomes `{version, input}`.",
            "- `WILLDEEP_MEDIA_PROVIDER`: provider label written back into the manifest, such as `replicate`, `some_im`, `kling`, or `skill`.",
            "- `WILLDEEP_MEDIA_MODEL`: provider model/version name.",
            "- `WILLDEEP_MEDIA_TIMEOUT_SECONDS`: HTTP timeout, default `300`.",
            "- `WILLDEEP_MEDIA_POLL_URL_TEMPLATE`: async poll URL template, use `{id}` for job id.",
            "- `WILLDEEP_MEDIA_CANCEL_URL_TEMPLATE`: async cancel URL template, use `{id}` for job id when the submit response only returns an id.",
            "- `WILLDEEP_MEDIA_SUBMIT_ONLY`: set to `1` to submit remote async jobs, write pending task ids/URLs into the manifest, and let WillDeep track them without waiting for downloads.",
            "- `WILLDEEP_MEDIA_ONLY_FAILED`: set to `1` to process only manifest items that still carry `last_error` from a previous failed Ruby/API run.",
            "- `WILLDEEP_MEDIA_POLL_INTERVAL_SECONDS`: async poll interval, default `5`.",
            "- `WILLDEEP_MEDIA_POLL_MAX_ATTEMPTS`: async poll limit, default `120`.",
            "- `WILLDEEP_MEDIA_DONE_STATUSES`: comma-separated success statuses, default `succeeded,completed,complete,finished,done,success`.",
            "- `WILLDEEP_MEDIA_FAILED_STATUSES`: comma-separated failure statuses, default `failed,canceled,cancelled,error,timeout`.",
            "",
            "Provider preset hints:",
            "",
            "- Replicate Predictions: set `WILLDEEP_MEDIA_PROVIDER=replicate`, `WILLDEEP_MEDIA_API_URL=https://api.replicate.com/v1/predictions`, `WILLDEEP_MEDIA_API_TOKEN` to your private token, `WILLDEEP_MEDIA_MODEL` to the workflow/model version, `WILLDEEP_MEDIA_REQUEST_PRESET=replicate_predictions`, and usually `WILLDEEP_MEDIA_SUBMIT_ONLY=1` so WillDeep can track async predictions from the Media Tasks side panel.",
            "- some.im gateway: set `WILLDEEP_MEDIA_PROVIDER=some_im`, point `WILLDEEP_MEDIA_API_URL` at your image/video gateway route, keep credentials in `WILLDEEP_MEDIA_API_TOKEN` or `WILLDEEP_MEDIA_EXTRA_HEADERS_JSON`, and set `WILLDEEP_MEDIA_STATUS_ENDPOINT_SUFFIX` / `WILLDEEP_MEDIA_CANCEL_ENDPOINT_SUFFIX` when your gateway returns only an id.",
            "- Existing source-image / mask tasks: for `image_inpaint`, `image_erase`, or `image_upscale` manifest items, the Ruby template forwards `source_image_path` and `mask_path`; use `WILLDEEP_MEDIA_REQUEST_FORMAT=multipart` for file upload APIs or `WILLDEEP_MEDIA_EMBED_LOCAL_FILES=1` when the API expects data URLs in JSON.",
            "",
            "The Ruby template can consume direct binary responses, JSON media URLs, JSON base64 media, or async job/prediction responses that require polling.",
            "If a script only submits remote jobs and exits before outputs are ready, set `WILLDEEP_MEDIA_SUBMIT_ONLY=1` or write `remote_task_id` / `status_url` / `cancel_url` into manifest items, then call `import_media_manifest` with `import_pending_tasks: true` so the Media Tasks side panel can show and cancel those active jobs. If the provider only returns an id and needs a custom some.im route, also write `status_endpoint_suffix` and `cancel_endpoint_suffix` so refresh/cancel keeps working after App restart.",
            "For editing, assembly, or delivery scripts, read `production-timeline.json` first; it is ordered by episode and shot and carries each shot's selected image, video paths, image paths, prompt, and open review count. For machine-readable gap planning, read `production-gap-report.json`; it lists missing character/scene reference images, each asset's `linked_shot_ids`, missing-image shots, missing-video shots, open review counts, ready-to-run per-shot `short_drama_generate_shot_media` dry-run / submit arguments, ready-to-run asset-scoped `short_drama_generate_batch_media(shot_ids=...)` dry-run / submit arguments, ready-to-run `short_drama_generate_asset_media` dry-run / submit arguments, and ready-to-run project/episode `short_drama_generate_batch_media(target_filter=missing)` dry-run / submit arguments. When this package is exported for one episode, gap report `batch_actions` include `episode_id` so batch generation stays inside that episode. For spreadsheets, offline review, or NLE prep, read `production-shot-list.csv`, which flattens the same shot order into one row per shot. To send review notes back into WillDeep, fill `production-review-template.csv` and import it with `short_drama_import_review_csv(package_directory: <this package directory>)` or the Short Drama side-panel review CSV buttons. To process existing open reviewItems outside WillDeep, read `production-review-queue.csv`, which flattens each unresolved review item into a repair task row with `recommended_tool`, `recommended_arguments`, review-task scope arguments, and resolve arguments. The Ruby template can also update `production-review-queue.csv` when a manifest item carries `review_item_id`; after the script marks rows `doing` or `resolved`, import that CSV with `short_drama_import_review_csv(file_path: <this package directory>/production-review-queue.csv)` to update or close the App's reviewItems.",
            "",
            "4. Dry-run the import in WillDeep Agent:",
            "",
            "```json",
            "{\"tool\":\"import_media_manifest\",\"arguments\":{\"package_directory\":\"<this package directory>\",\"dry_run\":true}}",
            "```",
            "",
            "For submit-only async jobs, include `import_pending_tasks` in the dry-run and import calls:",
            "",
            "```json",
            "{\"tool\":\"import_media_manifest\",\"arguments\":{\"package_directory\":\"<this package directory>\",\"import_pending_tasks\":true,\"dry_run\":true}}",
            "```",
            "",
            "5. Import completed outputs:",
            "",
            "```json",
            "{\"tool\":\"import_media_manifest\",\"arguments\":{\"package_directory\":\"<this package directory>\"}}",
            "```",
            "",
            "6. Preview script progress or custom review UI in WillDeep:",
            "",
            "```json",
            "{\"tool\":\"show_widget\",\"arguments\":{\"title\":\"短剧制作预览\",\"html_path\":\"<this package directory>/widget-preview.html\"}}",
            "```",
            "",
            "## Logline",
            "",
            package.project.logline?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? package.project.logline! : "(none)",
            "",
            "## Characters",
            "",
        ]

        if package.project.characters.isEmpty {
            lines.append("- (none)")
        } else {
            for character in package.project.characters {
                lines.append("- \(character.name) (\(character.id.uuidString))")
                appendIndented("Description", character.description, to: &lines)
                appendIndented("Visual prompt", character.visualPrompt, to: &lines)
                appendIndentedList("Reference images", character.referenceImagePaths, to: &lines)
            }
        }

        lines += ["", "## Scenes", ""]
        if package.project.scenes.isEmpty {
            lines.append("- (none)")
        } else {
            for scene in package.project.scenes {
                lines.append("- \(scene.name) (\(scene.id.uuidString))")
                appendIndented("Description", scene.description, to: &lines)
                appendIndented("Visual prompt", scene.visualPrompt, to: &lines)
                appendIndentedList("Reference images", scene.referenceImagePaths, to: &lines)
            }
        }

        lines += ["", "## Episodes", ""]
        for episode in package.project.episodes.sorted(by: { $0.order < $1.order }) {
            lines += [
                "### EP\(episode.order) \(episode.title)",
                "",
                episode.summary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? episode.summary! : "(no summary)",
                "",
            ]
            for shot in episode.shots.sorted(by: { $0.order < $1.order }) {
                let characters = shot.characterIDs.map(\.uuidString).joined(separator: ", ")
                lines += [
                    "#### Shot \(shot.order): \(shot.title)",
                    "",
                    "- Shot id: \(shot.id.uuidString)",
                    "- Status: \(shot.status.rawValue)",
                    "- Scene id: \(shot.sceneID?.uuidString ?? "(none)")",
                    "- Character ids: \(characters.isEmpty ? "(none)" : characters)",
                    "- Selected artifact: \(shot.selectedArtifactPath ?? "(none)")",
                    "- Artifacts: \(shot.artifactPaths.isEmpty ? "(none)" : "")",
                ]
                for path in shot.artifactPaths {
                    lines.append("  - \(path)")
                }
                lines += [
                    "- Summary: \(shot.summary ?? "(none)")",
                    "- Prompt: \(shot.prompt ?? "(none)")",
                    "- Review items\(includeResolvedReviewItems ? "" : " (open only)"):",
                ]
                if shot.reviewItems.isEmpty {
                    lines.append("  - (none)")
                } else {
                    for item in shot.reviewItems {
                        lines.append("  - [\(item.status.rawValue)/\(item.kind.rawValue)/\(item.severity.rawValue)] \(item.title) (\(item.id.uuidString))")
                        appendNested("Detail", item.detail, to: &lines)
                        appendNested("Suggested action", item.suggestedAction, to: &lines)
                        if !item.artifactPaths.isEmpty {
                            lines.append("    - Artifacts:")
                            for path in item.artifactPaths {
                                lines.append("      - \(path)")
                            }
                        }
                    }
                }
                lines.append("")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func productionPackageHandoffMarkdown(directory: URL) -> String {
        let packageDirectory = directory.path
        let manifestURL = directory.appendingPathComponent("media-import-manifest-template.json", isDirectory: false)
        let widgetPreviewURL = directory.appendingPathComponent("widget-preview.html", isDirectory: false)
        let reviewTemplateURL = directory.appendingPathComponent("production-review-template.csv", isDirectory: false)
        let reviewQueueURL = directory.appendingPathComponent("production-review-queue.csv", isDirectory: false)
        let gapReportURL = directory.appendingPathComponent("production-gap-report.json", isDirectory: false)
        let timelineURL = directory.appendingPathComponent("production-timeline.json", isDirectory: false)
        let shotListURL = directory.appendingPathComponent("production-shot-list.csv", isDirectory: false)
        return [
            "<production-package-handoff>",
            "action: production_package_markdown_handoff",
            "package_directory: \(packageDirectory)",
            "manifest_path: \(manifestURL.path)",
            "widget_preview_path: \(widgetPreviewURL.path)",
            "review_template_path: \(reviewTemplateURL.path)",
            "review_queue_path: \(reviewQueueURL.path)",
            "gap_report_path: \(gapReportURL.path)",
            "timeline_path: \(timelineURL.path)",
            "shot_list_path: \(shotListURL.path)",
            "dry_run_import_tool: import_media_manifest",
            "dry_run_import_arguments: package_directory=\(packageDirectory), dry_run=true, import_pending_tasks=true",
            "submit_import_tool: import_media_manifest",
            "submit_import_arguments: package_directory=\(packageDirectory), dry_run=false, import_pending_tasks=true",
            "review_template_import_tool: short_drama_import_review_csv",
            "review_template_import_arguments: package_directory=\(packageDirectory), dry_run=true",
            "review_queue_import_tool: short_drama_import_review_csv",
            "review_queue_import_arguments: file_path=\(reviewQueueURL.path), dry_run=true",
            "widget_tool: show_widget",
            "widget_arguments: title=短剧制作预览, html_path=\(widgetPreviewURL.path), source_label=production-package.md, source_path=\(directory.appendingPathComponent("production-package.md", isDirectory: false).path), package_directory=\(packageDirectory), recommended_tool=import_media_manifest, recommended_arguments=package_directory=\(packageDirectory), dry_run=true, import_pending_tasks=true",
            "</production-package-handoff>"
        ].joined(separator: "\n")
    }

    private static func mediaImportManifestTemplate(for project: AgentShortDramaProject) -> MediaImportManifestTemplate {
        var items: [MediaImportManifestTemplate.Item] = []
        for character in project.characters {
            items.append(
                MediaImportManifestTemplate.Item(
                    filePath: "\(assetFileStem(kind: "character", name: character.name, id: character.id))-reference.png",
                    title: "\(character.name) reference",
                    taskTitle: "\(character.name) · 角色参考图",
                    kind: "image_generation",
                    prompt: character.visualPrompt ?? character.description,
                    model: nil,
                    projectID: project.id.uuidString,
                    episodeID: nil,
                    shotID: nil,
                    assetKind: "character",
                    assetID: character.id.uuidString
                )
            )
        }
        for scene in project.scenes {
            items.append(
                MediaImportManifestTemplate.Item(
                    filePath: "\(assetFileStem(kind: "scene", name: scene.name, id: scene.id))-reference.png",
                    title: "\(scene.name) reference",
                    taskTitle: "\(scene.name) · 场景参考图",
                    kind: "image_generation",
                    prompt: scene.visualPrompt ?? scene.description,
                    model: nil,
                    projectID: project.id.uuidString,
                    episodeID: nil,
                    shotID: nil,
                    assetKind: "scene",
                    assetID: scene.id.uuidString
                )
            )
        }
        for episode in project.episodes.sorted(by: { $0.order < $1.order }) {
            for shot in episode.shots.sorted(by: { $0.order < $1.order }) {
                let stem = shotFileStem(episode: episode, shot: shot)
                items.append(
                    MediaImportManifestTemplate.Item(
                        filePath: "\(stem)-image.png",
                        title: "\(episode.title) · \(shot.title) key image",
                        taskTitle: "\(shot.title) · 分镜图片",
                        kind: "image_generation",
                        prompt: AgentShortDramaPromptBuilder.prompt(project: project, shot: shot),
                        model: nil,
                        projectID: project.id.uuidString,
                        episodeID: episode.id.uuidString,
                        shotID: shot.id.uuidString,
                        assetKind: nil,
                        assetID: nil
                    )
                )
                items.append(
                    MediaImportManifestTemplate.Item(
                        filePath: "\(stem)-video.mp4",
                        title: "\(episode.title) · \(shot.title) video",
                        taskTitle: "\(shot.title) · 分镜视频",
                        kind: "video_generation",
                        prompt: AgentShortDramaPromptBuilder.prompt(project: project, shot: shot),
                        model: nil,
                        projectID: project.id.uuidString,
                        episodeID: episode.id.uuidString,
                        shotID: shot.id.uuidString,
                        assetKind: nil,
                        assetID: nil
                    )
                )
                for reviewItem in shot.reviewItems where reviewItem.status != .resolved {
                    guard let repairKind = repairManifestKind(for: reviewItem.kind) else { continue }
                    let reviewStem = "\(stem)-review-\(reviewItem.id.uuidString.prefix(8))"
                    let extensionName = repairKind == "video_generation" ? "mp4" : "png"
                    let sourcePath = selectedImagePath(for: shot)
                    items.append(
                        MediaImportManifestTemplate.Item(
                            filePath: "\(reviewStem)-\(reviewItem.kind.rawValue).\(extensionName)",
                            title: "\(episode.title) · \(shot.title) · \(reviewItem.title)",
                            taskTitle: "\(shot.title) · \(reviewItem.kind.displayName)修复",
                            kind: repairKind,
                            prompt: reviewRepairPrompt(project: project, shot: shot, item: reviewItem),
                            model: nil,
                            sourceImagePath: sourcePath,
                            maskPath: nil,
                            projectID: project.id.uuidString,
                            episodeID: episode.id.uuidString,
                            shotID: shot.id.uuidString,
                            assetKind: nil,
                            assetID: nil,
                            reviewItemID: reviewItem.id.uuidString,
                            suggestedAction: reviewItem.suggestedAction
                        )
                    )
                }
            }
        }
        return MediaImportManifestTemplate(
            title: "\(project.title) media import",
            baseDirectory: "outputs",
            provider: "skill",
            projectID: project.id.uuidString,
            items: items
        )
    }

    private static func repairManifestKind(for kind: AgentShortDramaReviewItemKind) -> String? {
        switch kind {
        case .redraw:
            return "image_inpaint"
        case .erase:
            return "image_erase"
        case .upscale:
            return "image_upscale"
        case .reshoot:
            return "image_generation"
        case .continuity, .prompt, .note:
            return nil
        }
    }

    private static func reviewRepairPrompt(
        project: AgentShortDramaProject,
        shot: AgentShortDramaShot,
        item: AgentShortDramaReviewItem
    ) -> String {
        var parts = [
            "Project: \(project.title)",
            "Shot: \(shot.title)",
            "Review item: \(item.title)",
            "Kind: \(item.kind.rawValue)",
            "Severity: \(item.severity.rawValue)"
        ]
        if let summary = shot.summary, !summary.isEmpty {
            parts.append("Shot summary: \(summary)")
        }
        if let shotPrompt = shot.prompt, !shotPrompt.isEmpty {
            parts.append("Original shot prompt: \(shotPrompt)")
        }
        if let detail = item.detail, !detail.isEmpty {
            parts.append("Issue detail: \(detail)")
        }
        if let suggestedAction = item.suggestedAction, !suggestedAction.isEmpty {
            parts.append("Suggested action: \(suggestedAction)")
        }
        return parts.joined(separator: "\n")
    }

    private static func timeline(for package: Package) -> Timeline {
        let project = package.project
        let episodes = project.episodes.sorted(by: { $0.order < $1.order }).map { episode in
            Timeline.Episode(
                id: episode.id.uuidString,
                order: episode.order,
                title: episode.title,
                summary: episode.summary,
                shots: episode.shots.sorted(by: { $0.order < $1.order }).map { shot in
                    Timeline.Shot(
                        id: shot.id.uuidString,
                        order: shot.order,
                        title: shot.title,
                        status: shot.status.rawValue,
                        summary: shot.summary,
                        prompt: shot.prompt,
                        selectedImagePath: selectedImagePath(for: shot),
                        videoPaths: shot.artifactPaths.filter(isVideoPath),
                        imagePaths: shot.artifactPaths.filter(isImagePath),
                        artifactPaths: shot.artifactPaths,
                        openReviewItemCount: shot.reviewItems.filter { $0.status != .resolved }.count
                    )
                }
            )
        }
        return Timeline(
            exportedAt: package.exportedAt,
            scope: package.scope,
            projectID: project.id.uuidString,
            projectTitle: project.title,
            logline: project.logline,
            episodes: episodes
        )
    }

    private static func gapReport(for package: Package) -> GapReport {
        let project = package.project
        let assets = gapReportAssets(for: project)
        let episodes = project.episodes.sorted(by: { $0.order < $1.order }).map { episode in
            let shots = episode.shots.sorted(by: { $0.order < $1.order }).map { shot in
                let missingImage = selectedImagePath(for: shot) == nil
                let videoPaths = shot.artifactPaths.filter(isVideoPath)
                let missingVideo = videoPaths.isEmpty
                let openReviewCount = shot.reviewItems.filter { $0.status != .resolved }.count
                let baseArguments = "project_id=\(project.id.uuidString), episode_id=\(episode.id.uuidString), shot_id=\(shot.id.uuidString)"
                return GapReport.Shot(
                    id: shot.id.uuidString,
                    order: shot.order,
                    title: shot.title,
                    status: shot.status.rawValue,
                    missingImage: missingImage,
                    missingVideo: missingVideo,
                    openReviewItemCount: openReviewCount,
                    selectedImagePath: selectedImagePath(for: shot),
                    videoPaths: videoPaths,
                    imageDryRunArguments: missingImage ? "\(baseArguments), kind=image_generation, dry_run=true" : nil,
                    imageSubmitArguments: missingImage ? "\(baseArguments), kind=image_generation, dry_run=false" : nil,
                    videoDryRunArguments: missingVideo ? "\(baseArguments), kind=video_generation, dry_run=true" : nil,
                    videoSubmitArguments: missingVideo ? "\(baseArguments), kind=video_generation, dry_run=false" : nil,
                    reviewTasksArguments: openReviewCount > 0 ? "\(baseArguments), scope=shot" : nil
                )
            }
            return GapReport.Episode(
                id: episode.id.uuidString,
                order: episode.order,
                title: episode.title,
                missingImageCount: shots.filter(\.missingImage).count,
                missingVideoCount: shots.filter(\.missingVideo).count,
                openReviewItemCount: shots.reduce(0) { $0 + $1.openReviewItemCount },
                shots: shots
            )
        }
        let actionPrefix = gapReportBatchActionPrefix(for: package)
        let batchActions = GapReport.BatchActions(
            imageDryRunArguments: "\(actionPrefix), kind=image_generation, target_filter=missing, dry_run=true",
            imageSubmitArguments: "\(actionPrefix), kind=image_generation, target_filter=missing, dry_run=false",
            videoDryRunArguments: "\(actionPrefix), kind=video_generation, target_filter=missing, dry_run=true",
            videoSubmitArguments: "\(actionPrefix), kind=video_generation, target_filter=missing, dry_run=false"
        )
        return GapReport(
            exportedAt: package.exportedAt,
            scope: package.scope,
            projectID: project.id.uuidString,
            projectTitle: project.title,
            missingImageCount: episodes.reduce(0) { $0 + $1.missingImageCount },
            missingVideoCount: episodes.reduce(0) { $0 + $1.missingVideoCount },
            missingAssetReferenceCount: assets.filter(\.missingReference).count,
            openReviewItemCount: episodes.reduce(0) { $0 + $1.openReviewItemCount },
            episodes: episodes,
            assets: assets,
            batchActions: batchActions
        )
    }

    private static func gapReportBatchActionPrefix(for package: Package) -> String {
        let projectID = package.project.id.uuidString
        guard package.scope == "episode",
              package.project.episodes.count == 1,
              let episodeID = package.project.episodes.first?.id.uuidString else {
            return "project_id=\(projectID)"
        }
        return "project_id=\(projectID), episode_id=\(episodeID)"
    }

    private static func gapReportAssets(for project: AgentShortDramaProject) -> [GapReport.Asset] {
        let characterAssets = project.characters.map { character in
            gapReportAsset(
                projectID: project.id.uuidString,
                kind: "character",
                id: character.id.uuidString,
                name: character.name,
                referenceImageCount: character.referenceImagePaths.count,
                linkedShotIDs: linkedShotIDs(forCharacterID: character.id, in: project)
            )
        }
        let sceneAssets = project.scenes.map { scene in
            gapReportAsset(
                projectID: project.id.uuidString,
                kind: "scene",
                id: scene.id.uuidString,
                name: scene.name,
                referenceImageCount: scene.referenceImagePaths.count,
                linkedShotIDs: linkedShotIDs(forSceneID: scene.id, in: project)
            )
        }
        return characterAssets + sceneAssets
    }

    private static func gapReportAsset(
        projectID: String,
        kind: String,
        id: String,
        name: String,
        referenceImageCount: Int,
        linkedShotIDs: [String]
    ) -> GapReport.Asset {
        let taskArguments = "project_id=\(projectID), scope=asset, asset_kind=\(kind), asset_id=\(id)"
        let generateDryRunArguments = "project_id=\(projectID), asset_kind=\(kind), asset_id=\(id), dry_run=true"
        let generateArguments = "project_id=\(projectID), asset_kind=\(kind), asset_id=\(id), dry_run=false"
        let linkedShotArguments = linkedShotIDs.isEmpty ? nil : "project_id=\(projectID), shot_ids=[\(linkedShotIDs.joined(separator: ","))]"
        return GapReport.Asset(
            id: id,
            kind: kind,
            name: name,
            referenceImageCount: referenceImageCount,
            missingReference: referenceImageCount == 0,
            linkedShotCount: linkedShotIDs.count,
            linkedShotIDs: linkedShotIDs,
            openTasksArguments: taskArguments,
            refreshTasksArguments: taskArguments,
            generateReferenceDryRunArguments: referenceImageCount == 0 ? generateDryRunArguments : nil,
            generateReferenceArguments: referenceImageCount == 0 ? generateArguments : nil,
            linkedShotImageDryRunArguments: linkedShotArguments.map { "\($0), kind=image_generation, target_filter=missing, dry_run=true" },
            linkedShotImageSubmitArguments: linkedShotArguments.map { "\($0), kind=image_generation, target_filter=missing, dry_run=false" },
            linkedShotVideoDryRunArguments: linkedShotArguments.map { "\($0), kind=video_generation, target_filter=missing, dry_run=true" },
            linkedShotVideoSubmitArguments: linkedShotArguments.map { "\($0), kind=video_generation, target_filter=missing, dry_run=false" }
        )
    }

    private static func shotListCSV(for package: Package) -> String {
        let header = [
            "project_id",
            "project_title",
            "episode_id",
            "episode_order",
            "episode_title",
            "shot_id",
            "shot_order",
            "shot_title",
            "status",
            "selected_image_path",
            "video_paths",
            "image_paths",
            "artifact_count",
            "open_review_item_count",
            "summary",
            "prompt"
        ]
        var rows = [csvRow(header)]
        let project = package.project
        for episode in project.episodes.sorted(by: { $0.order < $1.order }) {
            for shot in episode.shots.sorted(by: { $0.order < $1.order }) {
                let videoPaths = shot.artifactPaths.filter(isVideoPath)
                let imagePaths = shot.artifactPaths.filter(isImagePath)
                rows.append(
                    csvRow([
                        project.id.uuidString,
                        project.title,
                        episode.id.uuidString,
                        String(episode.order),
                        episode.title,
                        shot.id.uuidString,
                        String(shot.order),
                        shot.title,
                        shot.status.rawValue,
                        selectedImagePath(for: shot) ?? "",
                        videoPaths.joined(separator: "\n"),
                        imagePaths.joined(separator: "\n"),
                        String(shot.artifactPaths.count),
                        String(shot.reviewItems.filter { $0.status != .resolved }.count),
                        shot.summary ?? "",
                        shot.prompt ?? ""
                    ])
                )
            }
        }
        return rows.joined(separator: "\n") + "\n"
    }

    private static func reviewTemplateCSV(for package: Package) -> String {
        let header = [
            "project_id",
            "project_title",
            "episode_id",
            "episode_order",
            "episode_title",
            "shot_id",
            "shot_order",
            "shot_title",
            "shot_status",
            "selected_image_path",
            "video_paths",
            "image_paths",
            "artifact_count",
            "open_review_item_count",
            "summary",
            "prompt",
            "review_title",
            "detail",
            "kind",
            "severity",
            "review_status",
            "suggested_action",
            "artifact_paths",
            "review_item_id"
        ]
        var rows = [csvRow(header)]
        let project = package.project
        for episode in project.episodes.sorted(by: { $0.order < $1.order }) {
            for shot in episode.shots.sorted(by: { $0.order < $1.order }) {
                let videoPaths = shot.artifactPaths.filter(isVideoPath)
                let imagePaths = shot.artifactPaths.filter(isImagePath)
                rows.append(
                    csvRow([
                        project.id.uuidString,
                        project.title,
                        episode.id.uuidString,
                        String(episode.order),
                        episode.title,
                        shot.id.uuidString,
                        String(shot.order),
                        shot.title,
                        shot.status.rawValue,
                        selectedImagePath(for: shot) ?? "",
                        videoPaths.joined(separator: "\n"),
                        imagePaths.joined(separator: "\n"),
                        String(shot.artifactPaths.count),
                        String(shot.reviewItems.filter { $0.status != .resolved }.count),
                        shot.summary ?? "",
                        shot.prompt ?? "",
                        "",
                        "",
                        "note",
                        "medium",
                        "open",
                        "",
                        selectedImagePath(for: shot) ?? "",
                        ""
                    ])
                )
            }
        }
        return rows.joined(separator: "\n") + "\n"
    }

    nonisolated static func csvRow(_ fields: [String]) -> String {
        fields.map(csvField).joined(separator: ",")
    }

    nonisolated static func csvField(_ raw: String) -> String {
        let escaped = raw.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    private static func exportDirectoryName(project: AgentShortDramaProject, episodeID: UUID?) -> String {
        let date = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: ".", with: "")
        let scope = episodeID?.uuidString.prefix(8) ?? "all"
        return "\(slug(project.title))-\(scope)-\(date)"
    }

    private static func slug(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let mapped = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let slug = String(mapped)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return slug.isEmpty ? "short-drama" : String(slug.prefix(60))
    }

    static func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func assetFileStem(kind: String, name: String, id: UUID) -> String {
        "\(kind)-\(slug(name))-\(id.uuidString.prefix(8))"
    }

    private static func shotFileStem(episode: AgentShortDramaEpisode, shot: AgentShortDramaShot) -> String {
        let episodeLabel = String(format: "ep%02d", episode.order)
        let shotLabel = String(format: "shot%03d", shot.order)
        return "\(episodeLabel)-\(shotLabel)-\(slug(shot.title))-\(shot.id.uuidString.prefix(8))"
    }

    private static func openReviewItemCount(in project: AgentShortDramaProject) -> Int {
        project.episodes.reduce(0) { episodeTotal, episode in
            episodeTotal + episode.shots.reduce(0) { shotTotal, shot in
                shotTotal + shot.reviewItems.filter { $0.status != .resolved }.count
            }
        }
    }

    private static func selectedArtifactCount(in project: AgentShortDramaProject) -> Int {
        project.episodes.reduce(0) { episodeTotal, episode in
            episodeTotal + episode.shots.filter { $0.selectedArtifactPath != nil }.count
        }
    }

    private static func artifactCount(in project: AgentShortDramaProject) -> Int {
        project.episodes.reduce(0) { episodeTotal, episode in
            episodeTotal + episode.shots.reduce(0) { $0 + $1.artifactPaths.count }
        }
    }

    nonisolated static func selectedImagePath(for shot: AgentShortDramaShot) -> String? {
        if let selected = shot.selectedArtifactPath, isImagePath(selected) {
            return selected
        }
        return shot.artifactPaths.first(where: isImagePath)
    }

    nonisolated static func isImagePath(_ path: String) -> Bool {
        ["png", "jpg", "jpeg", "webp", "gif", "tif", "tiff", "heic"].contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    nonisolated static func isVideoPath(_ path: String) -> Bool {
        ["mp4", "mov", "m4v", "webm"].contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    private static func appendIndented(_ label: String, _ value: String?, to lines: inout [String]) {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        lines.append("  - \(label): \(value)")
    }

    private static func appendIndentedList(_ label: String, _ values: [String], to lines: inout [String]) {
        guard !values.isEmpty else { return }
        lines.append("  - \(label):")
        for value in values {
            lines.append("    - \(value)")
        }
    }

    private static func appendNested(_ label: String, _ value: String?, to lines: inout [String]) {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        lines.append("    - \(label): \(value)")
    }
}
