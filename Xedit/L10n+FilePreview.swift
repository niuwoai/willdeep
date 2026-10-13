import Foundation

extension L10n {
    nonisolated enum FilePreview {
        static let unavailable = String(localized: "file-preview.unavailable", defaultValue: "Preview unavailable", table: "FilePreview")
        static let location = String(localized: "file-preview.location", defaultValue: "File location", table: "FilePreview")
        static let page = String(localized: "file-preview.page", defaultValue: "Page preview", table: "FilePreview")
        static let changes = String(localized: "file-preview.changes", defaultValue: "Changes", table: "FilePreview")
        static let htmlTooLarge = String(localized: "file-preview.html-too-large", defaultValue: "This HTML file exceeds the 1 MB preview limit. You can locate and open the complete file in Finder.", table: "FilePreview")
        static let unreadable = String(localized: "file-preview.unreadable", defaultValue: "This file cannot be read as a regular local document.", table: "FilePreview")
        static let invalidText = String(localized: "file-preview.invalid-text", defaultValue: "This file is binary or is not UTF-8 text.", table: "FilePreview")
        static let renderFailed = String(localized: "file-preview.render-failed", defaultValue: "The page renderer stopped. You can open the original file from Finder.", table: "FilePreview")
    }
}
