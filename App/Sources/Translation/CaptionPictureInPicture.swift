import AVKit
import Synchronization
import TranslatorCore
import UIKit

/// Presents the live caption list as video frames through the system's floating window.
@MainActor
final class CaptionPictureInPicture: NSObject {
    private enum Phase {
        case idle, preparing, starting, active, stopping
    }

    final class SourceView: UIView {
        override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }

        var videoLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
    }

    let sourceView = SourceView()
    var onStateChanged: (() -> Void)?
    var onStartFailed: (() -> Void)?

    var isEngaged: Bool { phase != .idle }
    var showsPreview: Bool { phase == .preparing || phase == .starting }

    private lazy var controller: AVPictureInPictureController = {
        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: sourceView.videoLayer, playbackDelegate: self
        )
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        controller.requiresLinearPlayback = true
        return controller
    }()

    private var phase = Phase.idle {
        didSet { onStateChanged?() }
    }
    private let paused = Mutex(false)
    private var feed: Task<Void, Never>?
    private var content = CaptionFrame.Content(rows: [], emptyText: "")
    private var frame: CaptionFrame?

    static func makeIfSupported() -> CaptionPictureInPicture? {
        AVPictureInPictureController.isPictureInPictureSupported() ? CaptionPictureInPicture() : nil
    }

    private override init() {
        super.init()
        sourceView.isUserInteractionEnabled = false
        sourceView.accessibilityElementsHidden = true
        sourceView.clipsToBounds = true
        sourceView.layer.cornerRadius = 12
        sourceView.videoLayer.videoGravity = .resizeAspect
    }

    func update(phrases: [Phrase], speaking: PhraseID?, emptyText: String) {
        // Six rows cover the canvas even when each has only one line.
        let rows = phrases.suffix(6).map { CaptionFrame.Row(phrase: $0, isSpeaking: $0.id == speaking) }
        let next = CaptionFrame.Content(rows: rows, emptyText: rows.isEmpty ? emptyText : "")
        guard next != content else { return }
        content = next
        if !paused.withLock({ $0 }) { frame = nil }
    }

    func toggle() {
        if isEngaged {
            stop()
        } else {
            start()
        }
    }

    private func start() {
        guard sourceView.window != nil else { return }
        paused.withLock { $0 = false }
        phase = .preparing
        controller.invalidatePlaybackState()
        let deadline = ContinuousClock.now + .seconds(3)
        feed = Task { [weak self] in
            while !Task.isCancelled, self?.sendFrame(startDeadline: deadline) == true {
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    func stop() {
        switch phase {
        case .preparing:
            finish()
        case .starting:
            // AVKit can only stop after the start animation completes.
            phase = .stopping
        case .active:
            phase = .stopping
            controller.stopPictureInPicture()
        case .idle, .stopping:
            break
        }
    }

    private func finish() {
        feed?.cancel()
        feed = nil
        frame = nil
        sourceView.videoLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        phase = .idle
    }

    private func sendFrame(startDeadline: ContinuousClock.Instant) -> Bool {
        guard isEngaged else { return false }
        let layer = sourceView.videoLayer
        let renderer = layer.sampleBufferRenderer
        if renderer.requiresFlushToResumeDecoding { renderer.flush() }
        if renderer.isReadyForMoreMediaData {
            if frame == nil { frame = CaptionFrame(content: content) }
            if let buffer = frame?.makeSampleBuffer() { renderer.enqueue(buffer) }
        }
        if phase == .preparing {
            if layer.isReadyForDisplay, controller.isPictureInPicturePossible {
                phase = .starting
                controller.startPictureInPicture()
            } else if ContinuousClock.now >= startDeadline {
                finish()
                onStartFailed?()
                return false
            }
        }
        return true
    }
}

extension CaptionPictureInPicture: AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in
            if phase == .stopping {
                controller.stopPictureInPicture()
            } else if phase == .starting {
                phase = .active
            }
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in finish() }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: any Error
    ) {
        Task { @MainActor in
            let showFailure = phase != .stopping
            finish()
            if showFailure { onStartFailed?() }
        }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        // The original caption list is already the main screen.
        completionHandler(true)
    }

    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        Task { @MainActor in
            paused.withLock { $0 = !playing }
            if playing { frame = nil }
            controller.invalidatePlaybackState()
        }
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        paused.withLock { $0 }
    }

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .zero, duration: .positiveInfinity)
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {
        // AVKit scales this fixed-aspect caption layout when the window is resized.
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion: @escaping () -> Void
    ) {
        completion()
    }
}
