import AVKit
import TranslatorCore
import UIKit
import UniformTypeIdentifiers

extension TranslationViewController {
    // MARK: View model

    func bindViewModel() {
        viewModel.onPhrasesChanged = { [weak self] changes in self?.apply(changes) }
        viewModel.onStatusChanged = { [weak self] status in self?.render(status: status) }
        viewModel.onLevelChanged = { [weak self] level in self?.levelMeter.set(level: level) }
        viewModel.onNoticeChanged = { [weak self] notice in self?.render(notice: notice) }
        viewModel.onSpeakingChanged = { [weak self] speaking in
            guard let self else { return }
            self.statusView.show(self.viewModel.status, speaking: speaking != nil)
        }
        viewModel.onSpeaksTranslationsChanged = { [weak self] _ in self?.renderSpeechToggle() }
        viewModel.onSpeechQueueChanged = { [weak self] in self?.renderJumpButton() }
        viewModel.onLanguagesChanged = { [weak self] in self?.renderLanguages() }
        viewModel.onTranslationCompleted = { [weak self] phrase in
            // With speech on, the phone reads it out already.
            guard UIAccessibility.isVoiceOverRunning, self?.viewModel.speaksTranslations == false,
                  let translation = phrase.translatedText, !phrase.isSpokenInTargetLanguage else { return }
            // Queued, so a new caption never cuts off the one being read.
            let announcement = NSAttributedString(string: translation, attributes: [
                .accessibilitySpeechQueueAnnouncement: true,
                .accessibilitySpeechLanguage: phrase.targetLanguage.rawValue,
            ])
            UIAccessibility.post(notification: .announcement, argument: announcement)
        }

        // Show whatever happened before the view loaded, such as a notice from
        // starting at launch.
        render(status: viewModel.status)
        render(notice: viewModel.notice)
        renderSpeechToggle()
        apply(TranslationViewModel.PhraseChanges(inserted: viewModel.phrases.map(\.id)))
    }

    func apply(_ changes: TranslationViewModel.PhraseChanges) {
        if let pictureInPicture, pictureInPicture.isEngaged { updatePictureInPicture(pictureInPicture) }
        var snapshot = dataSource.snapshot()
        let structureChanged = !changes.inserted.isEmpty || !changes.removed.isEmpty
        if structureChanged || snapshot.numberOfSections == 0 {
            snapshot = NSDiffableDataSourceSnapshot()
            snapshot.appendSections([0])
            snapshot.appendItems(viewModel.phrases.map(\.id))
        }
        let updated = changes.updated.filter { snapshot.indexOfItem($0) != nil }
        if !updated.isEmpty {
            snapshot.reconfigureItems(updated)
        }

        let follow = followsLatest
        // Revisions arrive many times a second; animating each one makes the
        // list shimmer, so only insertions and removals animate.
        let animate = structureChanged && !UIAccessibility.isReduceMotionEnabled
        dataSource.apply(snapshot, animatingDifferences: animate) { [weak self] in
            guard let self else { return }
            if follow {
                self.scrollToLatest(animated: animate)
            }
            self.updateEmptyState()
        }
    }
}
