import TranslatorCore
import UIKit
import UniformTypeIdentifiers

/// Language choices above the conversation, with listening controls,
/// connection status, and microphone level at the bottom.
final class TranslationViewController: UIViewController {
    private let viewModel: TranslationViewModel
    private let openAPIKeySettings: () -> Void

    private let statusView = ConnectionStatusView()
    private let levelMeter = LevelMeterView()
    private let sourceButton = UIButton(configuration: .tinted())
    private let targetButton = UIButton(configuration: .tinted())
    private let bidirectionalButton = UIButton(configuration: .gray())
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let emptyLabel = UILabel()
    private let noticeView = NoticeView()
    private let jumpButton = UIButton(configuration: .filled())
    private let startButton = UIButton(configuration: .filled())
    private let speakButton = UIButton(configuration: .gray())

    private var dataSource: UITableViewDiffableDataSource<Int, PhraseID>!
    private var pendingExport: URL?
    /// Whether new captions should scroll into view: true until the user
    /// scrolls up to read earlier ones.
    private var followsLatest = true

    init(viewModel: TranslationViewModel, openAPIKeySettings: @escaping () -> Void) {
        self.viewModel = viewModel
        self.openAPIKeySettings = openAPIKeySettings
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Translator")
        view.backgroundColor = .systemBackground
        configureNavigationItems()
        configureHeader()
        configureTable()
        configureNotice()
        configureButtons()
        layout()
        bindViewModel()
    }

    private func configureNavigationItems() {
        let newConversation = UIAction(title: String(localized: "New"), image: UIImage(systemName: "doc.badge.plus")) { [weak self] _ in
            self?.viewModel.clear()
        }
        let load = UIAction(title: String(localized: "Load"), image: UIImage(systemName: "folder")) { [weak self] _ in
            self?.chooseConversationFile()
        }
        let save = UIAction(title: String(localized: "Save"), image: UIImage(systemName: "square.and.arrow.down")) { [weak self] _ in
            self?.saveConversation()
        }
        let copyAll = UIAction(title: String(localized: "Copy"), image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
            guard let self else { return }
            self.copy(self.viewModel.transcript())
        }
        let apiKey = UIAction(title: String(localized: "Inworld API Key"), image: UIImage(systemName: "key")) { [weak self] _ in
            self?.openAPIKeySettings()
        }
        let conversation = UIMenu(options: .displayInline, children: [newConversation, load, save, copyAll])
        let more = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), menu: UIMenu(children: [conversation, apiKey]))
        more.preferredMenuElementOrder = .fixed
        more.accessibilityLabel = String(localized: "More")
        navigationItem.rightBarButtonItem = more
    }

    private func configureHeader() {
        configureLanguageButton(sourceButton, mode: .source)
        configureLanguageButton(targetButton, mode: .target)
        bidirectionalButton.accessibilityLabel = String(localized: "Bidirectional translation")
        bidirectionalButton.addAction(UIAction { [weak self] _ in
            self?.viewModel.toggleBidirectional()
        }, for: .primaryActionTriggered)
    }

    private func configureLanguageButton(_ button: UIButton, mode: LanguagePickerViewController.Mode) {
        button.configuration?.cornerStyle = .capsule
        button.configuration?.buttonSize = .small
        button.configuration?.titleLineBreakMode = .byTruncatingTail
        button.configuration?.image = UIImage(systemName: "chevron.down")
        button.configuration?.imagePlacement = .trailing
        button.configuration?.imagePadding = 6
        button.titleLabel?.numberOfLines = 1
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.titleLabel?.minimumScaleFactor = 0.6
        button.accessibilityLabel = mode.title
        button.addAction(UIAction { [weak self] _ in
            guard let self, self.viewModel.canChangeLanguages else { return }
            let current = mode == .source ? self.viewModel.sourceLanguage : self.viewModel.targetLanguage
            let picker = LanguagePickerViewController(mode: mode, current: current) { [weak self] language in
                switch mode {
                case .source:
                    self?.viewModel.setSourceLanguage(language)
                case .target:
                    if let language { self?.viewModel.setTargetLanguage(language) }
                }
            }
            self.navigationController?.pushViewController(picker, animated: true)
        }, for: .primaryActionTriggered)
    }

    private func configureTable() {
        tableView.register(PhraseCell.self, forCellReuseIdentifier: PhraseCell.reuseIdentifier)
        tableView.delegate = self
        tableView.allowsSelection = false
        tableView.keyboardDismissMode = .onDrag
        tableView.translatesAutoresizingMaskIntoConstraints = false

        dataSource = UITableViewDiffableDataSource(tableView: tableView) { [weak self] tableView, indexPath, id in
            let cell = tableView.dequeueReusableCell(withIdentifier: PhraseCell.reuseIdentifier, for: indexPath) as! PhraseCell
            if let self, let phrase = self.viewModel.phrase(for: id) {
                cell.configure(with: phrase, isSpeaking: self.viewModel.speaking == id)
            }
            cell.onCopy = { [weak self] text in self?.copy(text) }
            return cell
        }
        dataSource.defaultRowAnimation = .fade

        emptyLabel.text = String(localized: "Tap Start to listen.")
        emptyLabel.font = .preferredFont(forTextStyle: .body)
        emptyLabel.adjustsFontForContentSizeCategory = true
        emptyLabel.textColor = .secondaryLabel
        emptyLabel.textAlignment = .center
        emptyLabel.numberOfLines = 0
    }

    private func configureNotice() {
        noticeView.isHidden = true
        noticeView.translatesAutoresizingMaskIntoConstraints = false
        noticeView.onDismiss = { [weak self] in self?.viewModel.dismissNotice() }
        noticeView.onAction = { [weak self] in
            guard let self, let action = self.viewModel.notice?.action else { return }
            switch action {
            case .openSystemSettings:
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            case .openAPIKeySettings:
                self.openAPIKeySettings()
            }
        }
    }

    private func configureButtons() {
        var start = UIButton.Configuration.filled()
        start.cornerStyle = .capsule
        start.buttonSize = .large
        start.imagePadding = 8
        start.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.preferredFont(forTextStyle: .headline)
            return attributes
        }
        startButton.configuration = start
        startButton.translatesAutoresizingMaskIntoConstraints = false
        startButton.addAction(UIAction { [weak self] _ in self?.viewModel.toggle() }, for: .primaryActionTriggered)

        speakButton.translatesAutoresizingMaskIntoConstraints = false
        speakButton.accessibilityLabel = String(localized: "Speak Translations")
        speakButton.accessibilityHint = String(localized: "Reads translations aloud. Listening continues on supported headphone routes.")
        speakButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.viewModel.setSpeaksTranslations(!self.viewModel.speaksTranslations)
        }, for: .primaryActionTriggered)

        var jump = UIButton.Configuration.filled()
        jump.cornerStyle = .capsule
        jump.buttonSize = .large
        jump.title = String(localized: "Jump to Latest")
        jump.image = UIImage(systemName: "arrow.down")
        jump.imagePadding = 8
        jump.baseBackgroundColor = .secondarySystemBackground
        jump.baseForegroundColor = .label
        jumpButton.configuration = jump
        jumpButton.isHidden = true
        jumpButton.translatesAutoresizingMaskIntoConstraints = false
        jumpButton.addAction(UIAction { [weak self] _ in
            self?.followsLatest = true
            self?.scrollToLatest(animated: true)
        }, for: .primaryActionTriggered)
    }

    private func layout() {
        let languagePickers = UIStackView(arrangedSubviews: [sourceButton, targetButton])
        languagePickers.distribution = .fillEqually
        languagePickers.spacing = 8
        let languageRow = UIStackView(arrangedSubviews: [languagePickers, bidirectionalButton])
        languageRow.spacing = 8
        languageRow.translatesAutoresizingMaskIntoConstraints = false

        let controls = UIStackView(arrangedSubviews: [speakButton, startButton])
        controls.spacing = 12

        let statusRow = UIStackView(arrangedSubviews: [statusView, levelMeter])
        statusRow.alignment = .center
        statusRow.spacing = 12

        let bottomStack = UIStackView(arrangedSubviews: [noticeView, controls, statusRow])
        bottomStack.axis = .vertical
        bottomStack.spacing = 12
        bottomStack.setCustomSpacing(8, after: controls)
        bottomStack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(languageRow)
        view.addSubview(tableView)
        view.addSubview(jumpButton)
        view.addSubview(bottomStack)

        let margins = view.layoutMarginsGuide
        let readable = view.readableContentGuide
        NSLayoutConstraint.activate([
            languageRow.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            languageRow.leadingAnchor.constraint(equalTo: readable.leadingAnchor),
            languageRow.trailingAnchor.constraint(equalTo: readable.trailingAnchor),
            languageRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            bidirectionalButton.widthAnchor.constraint(equalToConstant: 44),

            tableView.topAnchor.constraint(equalTo: languageRow.bottomAnchor, constant: 8),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: bottomStack.topAnchor, constant: -8),

            jumpButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            jumpButton.bottomAnchor.constraint(equalTo: tableView.bottomAnchor, constant: -24),
            jumpButton.leadingAnchor.constraint(greaterThanOrEqualTo: readable.leadingAnchor),
            jumpButton.trailingAnchor.constraint(lessThanOrEqualTo: readable.trailingAnchor),
            jumpButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),

            bottomStack.leadingAnchor.constraint(equalTo: readable.leadingAnchor),
            bottomStack.trailingAnchor.constraint(equalTo: readable.trailingAnchor),
            bottomStack.bottomAnchor.constraint(equalTo: margins.bottomAnchor, constant: -8),
            startButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 56),
            speakButton.widthAnchor.constraint(equalTo: speakButton.heightAnchor),
            levelMeter.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        tableView.cellLayoutMarginsFollowReadableWidth = true
    }

    // MARK: View model

    private func bindViewModel() {
        viewModel.onPhrasesChanged = { [weak self] changes in self?.apply(changes) }
        viewModel.onStatusChanged = { [weak self] status in self?.render(status: status) }
        viewModel.onLevelChanged = { [weak self] level in self?.levelMeter.set(level: level) }
        viewModel.onNoticeChanged = { [weak self] notice in self?.render(notice: notice) }
        viewModel.onSpeakingChanged = { [weak self] speaking in
            guard let self else { return }
            self.statusView.show(self.viewModel.status, speaking: speaking != nil)
        }
        viewModel.onSpeaksTranslationsChanged = { [weak self] _ in self?.renderSpeechToggle() }
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

    private func apply(_ changes: TranslationViewModel.PhraseChanges) {
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
            } else if !changes.inserted.isEmpty {
                self.jumpButton.isHidden = false
            }
            self.updateEmptyState()
        }
    }

    private func render(status: SessionStatus) {
        statusView.show(status, speaking: viewModel.speaking != nil)
        renderLanguages()
        var configuration = startButton.configuration ?? .filled()
        if status.isRunning {
            configuration.title = String(localized: "Stop")
            configuration.image = UIImage(systemName: "stop.fill")
            configuration.baseBackgroundColor = .systemRed
            startButton.accessibilityHint = String(localized: "Stops listening and releases the microphone.")
        } else {
            configuration.title = String(localized: "Start")
            configuration.image = UIImage(systemName: "mic.fill")
            configuration.baseBackgroundColor = .tintColor
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

    private func render(notice: TranslationViewModel.Notice?) {
        if let notice {
            noticeView.show(notice)
            UIAccessibility.post(notification: .announcement, argument: notice.message)
        }
        UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.2) {
            self.noticeView.isHidden = notice == nil
            self.view.layoutIfNeeded()
        }
    }

    private func renderLanguages() {
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
        var configuration: UIButton.Configuration = on ? .tinted() : .gray()
        configuration.cornerStyle = .capsule
        configuration.image = UIImage(systemName: "arrow.left.arrow.right")
        bidirectionalButton.configuration = configuration
        bidirectionalButton.isEnabled = canChange && viewModel.canUseBidirectional
        bidirectionalButton.accessibilityValue = on ? String(localized: "On") : String(localized: "Off")
        bidirectionalButton.accessibilityHint = viewModel.canUseBidirectional
            ? String(localized: "Translates each selected language into the other.")
            : String(localized: "Choose two different languages to translate both ways.")
    }

    private func renderSpeechToggle() {
        let on = viewModel.speaksTranslations
        var configuration = on ? UIButton.Configuration.tinted() : UIButton.Configuration.gray()
        configuration.cornerStyle = .capsule
        configuration.buttonSize = .large
        configuration.image = UIImage(systemName: on ? "speaker.wave.2.fill" : "speaker.slash.fill")
        speakButton.configuration = configuration
        speakButton.accessibilityValue = on ? String(localized: "On") : String(localized: "Off")
    }

    private func updateEmptyState() {
        tableView.backgroundView = viewModel.phrases.isEmpty ? emptyLabel : nil
    }

    private func scrollToLatest(animated: Bool) {
        jumpButton.isHidden = true
        let rows = tableView.numberOfRows(inSection: 0)
        guard tableView.numberOfSections > 0, rows > 0 else { return }
        tableView.scrollToRow(at: IndexPath(row: rows - 1, section: 0), at: .bottom, animated: animated)
    }

    private func copy(_ text: String) {
        guard !text.isEmpty else { return }
        UIPasteboard.general.string = text
        UIAccessibility.post(notification: .announcement, argument: String(localized: "Copied"))
    }
}

// MARK: - Conversation files

extension TranslationViewController: UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {
    private func saveConversation() {
        let archive = ConversationArchive(phrases: viewModel.phrases)
        guard !archive.isEmpty else {
            showFileAlert(String(localized: "Nothing to Save"), message: String(localized: "A conversation needs at least one finalized caption."))
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
            showFileAlert(String(localized: "Couldn’t Save Conversation"), message: String(localized: "The conversation file couldn’t be created."))
        }
    }

    private func chooseConversationFile() {
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

    private func discardPendingExport() {
        guard let file = pendingExport else { return }
        pendingExport = nil
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    private func readConversationFile(_ file: URL) {
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
                self.showFileAlert(String(localized: "Couldn’t Load Conversation"), message: String(localized: "This version of the conversation file isn’t supported."))
            case .failure:
                self.showFileAlert(String(localized: "Couldn’t Load Conversation"), message: String(localized: "Choose a valid conversation file saved by Translator."))
            }
        }
    }

    private func confirmLoading(_ archive: ConversationArchive) {
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

    private func replaceConversation(with archive: ConversationArchive) {
        followsLatest = true
        if viewModel.replaceConversation(with: archive) {
            UIAccessibility.post(notification: .announcement, argument: String(localized: "Conversation loaded"))
        } else {
            showMustStopAlert()
        }
    }

    private func showMustStopAlert() {
        showFileAlert(String(localized: "Stop Before Loading"), message: String(localized: "Stop listening and wait for the last captions to finish before loading a conversation."))
    }

    private func showFileAlert(_ title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
        present(alert, animated: true)
    }
}

// MARK: - UITableViewDelegate

extension TranslationViewController: UITableViewDelegate {
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        followsLatest = false
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        updateFollowing(scrollView)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { updateFollowing(scrollView) }
    }

    func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
        followsLatest = false
    }

    /// Back at the bottom means the user wants to follow along again.
    private func updateFollowing(_ scrollView: UIScrollView) {
        let distanceFromBottom = scrollView.contentSize.height - scrollView.contentOffset.y - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
        followsLatest = distanceFromBottom < 40
        if followsLatest { jumpButton.isHidden = true }
    }

    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard let id = dataSource.itemIdentifier(for: indexPath), let phrase = viewModel.phrase(for: id) else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            var actions: [UIAction] = []
            if let translation = phrase.translatedText, !phrase.isSpokenInTargetLanguage {
                actions.append(UIAction(title: String(localized: "Copy Translation"), image: UIImage(systemName: "doc.on.doc")) { _ in self?.copy(translation) })
            }
            actions.append(UIAction(title: String(localized: "Copy Original"), image: UIImage(systemName: "text.quote")) { _ in self?.copy(phrase.sourceText) })
            if phrase.translatedText != nil, !phrase.isSpokenInTargetLanguage {
                actions.append(UIAction(title: String(localized: "Copy Both"), image: UIImage(systemName: "doc.on.clipboard")) { _ in
                    self?.copy(TranslationViewModel.text(for: phrase))
                })
            }
            return UIMenu(children: actions)
        }
    }
}
