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
        // Player control strip: tooltips and accessibility labels.
        static let play = String(localized: "transcript-media.control.play", defaultValue: "Play")
        static let pause = String(localized: "transcript-media.control.pause", defaultValue: "Pause")
        static let mute = String(localized: "transcript-media.control.mute", defaultValue: "Mute")
        static let unmute = String(localized: "transcript-media.control.unmute", defaultValue: "Unmute")
        static let volume = String(localized: "transcript-media.control.volume", defaultValue: "Volume")
        static let playbackPosition = String(
            localized: "transcript-media.control.position",
            defaultValue: "Playback Position"
        )
        static let elapsedTime = String(localized: "transcript-media.control.elapsed", defaultValue: "Elapsed Time")
        static let duration = String(localized: "transcript-media.control.duration", defaultValue: "Duration")
        static let fullScreen = String(localized: "transcript-media.control.full-screen", defaultValue: "Full Screen")
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
