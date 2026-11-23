import AVKit
import TranslatorCore
import UIKit
import UniformTypeIdentifiers

extension TranslationViewController {
    func render(status: SessionStatus) {
        statusView.show(status, speaking: viewModel.speaking != nil)
        renderLanguages()
        renderJumpButton()
        if let pictureInPicture, pictureInPicture.isEngaged {
            if status.isRunning {
                updatePictureInPicture(pictureInPicture)
            } else {
                pictureInPicture.stop()
            }
        }
        renderPictureInPictureButton()
        var configuration = startButton.configuration ?? .filled()
        if status.isRunning {
            configuration.title = String(localized: "Stop")
            configuration.image = UIImage(systemName: "stop.fill")
            configuration.baseBackgroundColor = TranslationTheme.stop
            startButton.accessibilityHint = String(localized: "Stops listening and releases the microphone.")
        } else {
            configuration.title = String(localized: "Start")
            configuration.image = UIImage(systemName: "mic.fill")
            configuration.baseBackgroundColor = TranslationTheme.primary
            startButton.accessibilityHint = String(localized: "Listens to speech and translates it into the selected language.")
            levelMeter.reset()
        }
        startButton.configuration = configuration
        // Captions are read at arm's length; don't let the screen lock mid-conversation.
        UIApplication.shared.isIdleTimerDisabled = status.isRunning

        switch status {
        case .listening, .reconnecting, .waitingForNetwork, .interrupted:
            UIAccessibility.post(notification: .announcement, argument: ConnectionStatusView.describe(status).0)
        default:
            break
        }
    }

    func render(notice: TranslationViewModel.Notice?) {
        if let notice {
            noticeView.show(notice)
            UIAccessibility.post(notification: .announcement, argument: notice.message)
        }
        UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.2) {
            self.noticeView.isHidden = notice == nil
            self.view.layoutIfNeeded()
        }
    }

    func renderLanguages() {
        let canChange = viewModel.canChangeLanguages
        sourceButton.isEnabled = canChange
        targetButton.isEnabled = canChange
        let source = viewModel.sourceLanguage?.name() ?? LanguagePickerViewController.autoDetectTitle
        sourceButton.configuration?.title = String(localized: "From · \(source)")
        sourceButton.accessibilityValue = source
        let target = viewModel.targetLanguage.name()
        targetButton.configuration?.title = String(localized: "To · \(target)")
        targetButton.accessibilityValue = target

        let on = viewModel.isBidirectional
        var configuration = toggleConfiguration(isOn: on)
        configuration.image = UIImage(systemName: "arrow.left.arrow.right", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold))
        bidirectionalButton.configuration = configuration
        bidirectionalButton.isEnabled = canChange && viewModel.canUseBidirectional
        bidirectionalButton.accessibilityValue = on ? String(localized: "On") : String(localized: "Off")
        bidirectionalButton.accessibilityHint = viewModel.canUseBidirectional
            ? String(localized: "Translates each selected language into the other.")
            : String(localized: "Choose two different languages to translate both ways.")
    }

    func renderSpeechToggle() {
        let on = viewModel.speaksTranslations
        var configuration = toggleConfiguration(isOn: on)
        configuration.buttonSize = .large
        configuration.image = UIImage(systemName: on ? "speaker.wave.2.fill" : "speaker.slash.fill")
        speakButton.configuration = configuration
        speakButton.accessibilityValue = on ? String(localized: "On") : String(localized: "Off")
        renderJumpButton()
    }

    private func toggleConfiguration(isOn: Bool) -> UIButton.Configuration {
        TranslationTheme.pill(
            fill: isOn ? TranslationTheme.original : TranslationTheme.translated,
            foreground: isOn ? TranslationTheme.accent : TranslationTheme.secondaryText
        )
    }

    func renderJumpButton() {
        jumpButton.isHidden = !viewModel.canJumpToLatestSpeech
    }

    func updatePictureInPicture(_ pictureInPicture: CaptionPictureInPicture) {
        pictureInPicture.update(phrases: viewModel.phrases, speaking: viewModel.speaking,
                                emptyText: ConnectionStatusView.describe(viewModel.status).0)
    }

    func renderPictureInPictureButton() {
        guard let pictureInPicture, let button = pictureInPictureButton else { return }
        if pictureInPicture.isEngaged {
            button.image = AVPictureInPictureController.pictureInPictureButtonStopImage
            button.accessibilityLabel = String(localized: "Stop Picture in Picture")
            button.isEnabled = true
        } else {
            button.image = AVPictureInPictureController.pictureInPictureButtonStartImage
            button.accessibilityLabel = String(localized: "Start Picture in Picture")
            let status = viewModel.status
            button.isEnabled = status.isRunning && status != .starting && status != .interrupted
        }
        // Show the video inline during the system's transition to the floating window.
        if pictureInPicture.showsPreview {
            view.insertSubview(pictureInPicture.sourceView, aboveSubview: tableView)
        } else {
            view.insertSubview(pictureInPicture.sourceView, belowSubview: tableView)
        }
    }

    func updateEmptyState() {
        tableView.backgroundView = viewModel.phrases.isEmpty ? emptyView : nil
    }

    func scrollToLatest(animated: Bool) {
        let rows = tableView.numberOfRows(inSection: 0)
        guard tableView.numberOfSections > 0, rows > 0 else { return }
        tableView.scrollToRow(at: IndexPath(row: rows - 1, section: 0), at: .bottom, animated: animated)
    }

    func copy(_ text: String) {
        guard !text.isEmpty else { return }
        UIPasteboard.general.string = text
        UIAccessibility.post(notification: .announcement, argument: String(localized: "Copied"))
    }

    func showAlert(_ title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
        present(alert, animated: true)
    }
}
