import UIKit

/// Opens the floating caption window when the app leaves the screen during a
/// listening session, and closes it on the way back.
@MainActor
final class AutomaticPictureInPicture {
    private let pictureInPicture: CaptionPictureInPicture
    private let canStart: () -> Bool
    private var startedAutomatically = false

    init(pictureInPicture: CaptionPictureInPicture, canStart: @escaping () -> Bool) {
        self.pictureInPicture = pictureInPicture
        self.canStart = canStart
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(appDidEnterBackground),
                           name: UIApplication.didEnterBackgroundNotification, object: nil)
        center.addObserver(self, selector: #selector(appWillEnterForeground),
                           name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func appDidEnterBackground() {
        guard canStart(), !pictureInPicture.isEngaged else { return }
        pictureInPicture.startAutomatically()
        startedAutomatically = pictureInPicture.isEngaged
    }

    /// The main screen shows the same captions, so the floating one is done.
    @objc private func appWillEnterForeground() {
        guard startedAutomatically else { return }
        startedAutomatically = false
        pictureInPicture.stop()
    }
}