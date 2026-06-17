import Foundation
import Testing
@testable import BlablacadabraCore

@Suite struct AudioDevicesTests {
    @Test func enumeratesDevicesConsistently() {
        // Every reported input device really has input channels, and ids/names
        // are non-empty. (Doesn't assume any particular device exists, so it
        // holds even on a machine with no audio hardware.)
        for device in AudioDevices.inputDevices() {
            #expect(device.hasInput)
            #expect(!device.uid.isEmpty)
            #expect(!device.name.isEmpty)
        }
        // If the system has a default input, the picker list includes it.
        if let defaultInput = AudioDevices.defaultInputDevice() {
            #expect(AudioDevices.inputDevices().contains { $0.uid == defaultInput.uid })
        }
    }

    @Test func flagsKnownCaptureBreakingOutputs() {
        let foxpro = AudioDevice(id: 1, uid: "foxpro-uid", name: "foxpro", hasInput: false, hasOutput: true)
        let speakers = AudioDevice(id: 2, uid: "spk", name: "MacBook Pro Speakers", hasInput: false, hasOutput: true)
        #expect(AudioDevices.isCaptureBreaking(foxpro))
        #expect(AudioDevices.isCaptureBreaking(AudioDevice(id: 3, uid: "fx2", name: "FoxPro Virtual", hasInput: false, hasOutput: true)))
        #expect(!AudioDevices.isCaptureBreaking(speakers))
    }
}

@Suite struct ModelSelectionTests {
    @Test func migratesBaseToSmall() {
        #expect(WhisperKitEngine.migratedModel(fromStored: "base") == "small")
        #expect(WhisperKitEngine.migratedModel(fromStored: "base") == WhisperKitEngine.defaultModel)
    }

    @Test func migratesNilAndUnknownToDefault() {
        #expect(WhisperKitEngine.migratedModel(fromStored: nil) == WhisperKitEngine.defaultModel)
        #expect(WhisperKitEngine.migratedModel(fromStored: "gigantic") == WhisperKitEngine.defaultModel)
    }

    @Test func keepsKnownModels() {
        #expect(WhisperKitEngine.migratedModel(fromStored: "tiny") == "tiny")
        #expect(WhisperKitEngine.migratedModel(fromStored: WhisperKitEngine.turboModel) == WhisperKitEngine.turboModel)
    }

    @Test func sliderIndexRoundTrips() {
        for (index, model) in WhisperKitEngine.availableModels.enumerated() {
            #expect(WhisperKitEngine.index(of: model) == index)
            #expect(WhisperKitEngine.model(atIndex: index) == model)
        }
        #expect(WhisperKitEngine.model(atIndex: 0) == "tiny")
        #expect(WhisperKitEngine.index(of: WhisperKitEngine.turboModel) == WhisperKitEngine.availableModels.count - 1)
    }

    @Test func sliderIndexClamps() {
        #expect(WhisperKitEngine.model(atIndex: -5) == WhisperKitEngine.availableModels.first)
        #expect(WhisperKitEngine.model(atIndex: 99) == WhisperKitEngine.availableModels.last)
    }

    @Test func displayNamesAreReadable() {
        #expect(WhisperKitEngine.displayName(for: "tiny") == "Tiny")
        #expect(WhisperKitEngine.displayName(for: "small") == "Small")
        #expect(WhisperKitEngine.displayName(for: "medium") == "Medium")
        #expect(WhisperKitEngine.displayName(for: WhisperKitEngine.turboModel) == "Turbo")
    }
}

@Suite struct LegacyCacheMigrationTests {
    /// Build a fake "models/argmaxinc/whisperkit-coreml/<variant>/marker" tree
    /// under `base` so we can assert moves without real model blobs.
    private func seedModel(_ variant: String, under base: URL, marker: String = "weights") throws {
        let dir = base
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(variant)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try marker.data(using: .utf8)!.write(to: dir.appendingPathComponent("marker.txt"))
    }

    private func modelExists(_ variant: String, under base: URL) -> Bool {
        let f = base
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(variant)/marker.txt", isDirectory: false)
        return FileManager.default.fileExists(atPath: f.path)
    }

    @Test func movesLegacyModelsAndRemovesEmptyLegacyTree() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("blabla-migrate-\(UUID().uuidString)")
        let legacy = root.appendingPathComponent("Documents/huggingface")
        let new = root.appendingPathComponent("AppSupport/Blablacadabra/huggingface")
        defer { try? fm.removeItem(at: root) }

        try seedModel("openai_whisper-tiny", under: legacy)
        try seedModel("openai_whisper-large-v3-turbo", under: legacy)

        WhisperKitEngine.migrateLegacyCache(legacyBase: legacy, newBase: new)

        #expect(modelExists("openai_whisper-tiny", under: new))
        #expect(modelExists("openai_whisper-large-v3-turbo", under: new))
        // Empty legacy tree is cleaned up entirely.
        #expect(!fm.fileExists(atPath: legacy.path))
    }

    @Test func keepsNewerCopyAndDropsStaleLegacyDuplicate() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("blabla-migrate-\(UUID().uuidString)")
        let legacy = root.appendingPathComponent("Documents/huggingface")
        let new = root.appendingPathComponent("AppSupport/Blablacadabra/huggingface")
        defer { try? fm.removeItem(at: root) }

        // Same variant in both; new (re-downloaded) copy must win, legacy dropped.
        try seedModel("openai_whisper-medium", under: legacy, marker: "OLD")
        try seedModel("openai_whisper-medium", under: new, marker: "NEW")

        WhisperKitEngine.migrateLegacyCache(legacyBase: legacy, newBase: new)

        let markerURL = new
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml/openai_whisper-medium/marker.txt")
        #expect((try? String(contentsOf: markerURL, encoding: .utf8)) == "NEW")
        #expect(!fm.fileExists(atPath: legacy.path)) // legacy emptied + removed
    }

    @Test func noLegacyFolderIsANoOp() {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("blabla-migrate-\(UUID().uuidString)")
        let legacy = root.appendingPathComponent("Documents/huggingface")
        let new = root.appendingPathComponent("AppSupport/Blablacadabra/huggingface")
        defer { try? fm.removeItem(at: root) }
        // Nothing seeded; must not crash or create anything.
        WhisperKitEngine.migrateLegacyCache(legacyBase: legacy, newBase: new)
        #expect(!fm.fileExists(atPath: new.path))
    }
}
