import AVFAudio

enum PlaybackRoute {
    static func allowsListening(voiceProcessingEnabled: Bool) -> Bool {
        let route = AVAudioSession.sharedInstance().currentRoute
        let handsFreeInput = route.inputs.first { $0.portType == .bluetoothHFP }
        let usesBuiltInMic = route.inputs.count == 1 && route.inputs.first?.portType == .builtInMic

        // Every active output must qualify. Generic Bluetooth outputs can be speakers.
        return !route.outputs.isEmpty && route.outputs.allSatisfy { output in
            switch output.portType {
            case .builtInSpeaker:
                return voiceProcessingEnabled && usesBuiltInMic
            case .headphones:
                return true
            case .bluetoothHFP:
                guard let handsFreeInput else { return false }
                return output.hasHardwareVoiceCallProcessing || handsFreeInput.hasHardwareVoiceCallProcessing
            default:
                return false
            }
        }
    }
}
