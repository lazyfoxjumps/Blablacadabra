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
