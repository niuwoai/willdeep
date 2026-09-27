//
//  L10n+TranscriptMedia.swift
//  WillDeep
//
//  Inline video / audio in the transcript, and saving images out of it.
//

import Foundation

extension L10n {
    enum TranscriptMedia {
        static let fileNotFound = String(
            localized: "transcript-media.file-not-found",
            defaultValue: "File not found"
        )
        static let unsupportedFormat = String(
            localized: "transcript-media.unsupported-format",
            defaultValue: "Can't play this format"
        )
        static let showInFinder = String(
            localized: "transcript-media.show-in-finder",
            defaultValue: "Show in Finder"
        )
        static func streamingVideo(_ name: String) -> String {
            let template = String(
                localized: "transcript-media.streaming-video",
                defaultValue: "Video · %@"
            )
            return String(format: template, name)
        }
        static func streamingAudio(_ name: String) -> String {
            let template = String(
                localized: "transcript-media.streaming-audio",
                defaultValue: "Audio · %@"
            )
            return String(format: template, name)
        }
    }

    enum ImageSave {
        static let saveAs = String(
            localized: "image-preview.save-as",
            defaultValue: "Save As…"
        )
        static let saveImageAction = String(
            localized: "agent-generated-image.save-action",
            defaultValue: "Save Image…"
        )
        static let failedTitle = String(
            localized: "image-save.failed-title",
            defaultValue: "Couldn't Save Image"
        )
        static let noImageData = String(
            localized: "image-save.no-image-data",
            defaultValue: "The image data is no longer available."
        )
    }
}
