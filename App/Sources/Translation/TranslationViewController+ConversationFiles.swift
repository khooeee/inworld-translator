import AVKit
import TranslatorCore
import UIKit
import UniformTypeIdentifiers

// MARK: - Conversation files

extension TranslationViewController: UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {
    func saveConversation() {
        let archive = ConversationArchive(phrases: viewModel.phrases)
        guard !archive.isEmpty else {
            showAlert(String(localized: "Nothing to Save"), message: String(localized: "A conversation needs at least one finalized caption."))
            return
        }
        do {
            let file = try archive.writeForExport()
            pendingExport = file
            let picker = UIDocumentPickerViewController(forExporting: [file], asCopy: true)
            picker.delegate = self
            picker.presentationController?.delegate = self
            present(picker, animated: true)
        } catch {
            showAlert(String(localized: "Couldn’t Save Conversation"), message: String(localized: "The conversation file couldn’t be created."))
        }
    }

    func chooseConversationFile() {
        guard viewModel.status == .idle else {
            showMustStopAlert()
            return
        }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.json], asCopy: true)
        picker.delegate = self
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        if pendingExport != nil {
            discardPendingExport()
            UIAccessibility.post(notification: .announcement, argument: String(localized: "Conversation saved"))
            return
        }
        guard let file = urls.first else { return }
        let load = { [weak self] in self?.readConversationFile(file) }
        if controller.isBeingDismissed, let transition = controller.transitionCoordinator,
           transition.animate(alongsideTransition: nil, completion: { _ in load() }) {
            return
        }
        if controller.presentingViewController != nil {
            controller.dismiss(animated: true) { load() }
        } else {
            load()
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        discardPendingExport()
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        discardPendingExport()
    }

    func discardPendingExport() {
        guard let file = pendingExport else { return }
        pendingExport = nil
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    func readConversationFile(_ file: URL) {
        let read = Task.detached {
            // Files gave us a temporary import copy.
            defer { try? FileManager.default.removeItem(at: file) }
            let data = try Data(contentsOf: file, options: .mappedIfSafe)
            return try ConversationArchive(data: data, maxPhrases: TranslationViewModel.maxPhrases)
        }
        Task { [weak self] in
            let result = await read.result
            guard let self else { return }
            switch result {
            case .success(let archive):
                self.confirmLoading(archive)
            case .failure(ConversationArchive.FileError.unsupportedVersion):
                self.showAlert(String(localized: "Couldn’t Load Conversation"), message: String(localized: "This version of the conversation file isn’t supported."))
            case .failure:
                self.showAlert(String(localized: "Couldn’t Load Conversation"), message: String(localized: "Choose a valid conversation file saved by Translator."))
            }
        }
    }

    func confirmLoading(_ archive: ConversationArchive) {
        guard viewModel.status == .idle else {
            showMustStopAlert()
            return
        }
        guard !viewModel.phrases.isEmpty else {
            replaceConversation(with: archive)
            return
        }
        let alert = UIAlertController(
            title: String(localized: "Replace Current Conversation?"),
            message: String(localized: "Loading this file will replace the captions on screen."),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "Replace"), style: .destructive) { [weak self] _ in
            self?.replaceConversation(with: archive)
        })
        present(alert, animated: true)
    }

    func replaceConversation(with archive: ConversationArchive) {
        followsLatest = true
        if viewModel.replaceConversation(with: archive) {
            UIAccessibility.post(notification: .announcement, argument: String(localized: "Conversation loaded"))
        } else {
            showMustStopAlert()
        }
    }

    func showMustStopAlert() {
        showAlert(String(localized: "Stop Before Loading"), message: String(localized: "Stop listening and wait for the last captions to finish before loading a conversation."))
    }
}
