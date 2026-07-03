import Foundation
import SwiftData
import os

/// Removes a transcription's on-disk audio (the main file plus any split chunks).
enum RecordingAudioFiles {
    static func removeAll(for transcription: Transcription) {
        if let s = transcription.audioFileURL, let u = URL(string: s) {
            try? FileManager.default.removeItem(at: u)
        }
        for url in transcription.audioChunkURLs {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

/// The one place Transcription deletion semantics live: remove the audio (incl. chunks),
/// delete the rows, save, and post `.transcriptionDeleted` once per batch. History views call
/// this instead of hand-rolling the sequence — two of them used to skip chunk files entirely,
/// leaking them on disk.
@MainActor
enum TranscriptionStore {
    private static let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "TranscriptionStore")

    static func delete(_ transcriptions: [Transcription], in context: ModelContext) {
        guard !transcriptions.isEmpty else { return }
        for transcription in transcriptions {
            RecordingAudioFiles.removeAll(for: transcription)
            context.delete(transcription)
        }
        do {
            try context.save()
        } catch {
            logger.error("Failed to save transcription deletion: \(error, privacy: .public)")
        }
        NotificationCenter.default.post(name: .transcriptionDeleted, object: nil)
    }

    static func delete(_ transcription: Transcription, in context: ModelContext) {
        delete([transcription], in: context)
    }
}
