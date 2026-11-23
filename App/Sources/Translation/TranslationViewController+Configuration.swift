import AVKit
import TranslatorCore
import UIKit
import UniformTypeIdentifiers

extension TranslationViewController {
    func configureNavigationItems() {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.titleTextAttributes = [
            .font: TranslationTheme.rounded(.systemFont(ofSize: 19, weight: .bold)),
            .foregroundColor: TranslationTheme.accent,
        ]
        navigationItem.standardAppearance = appearance
        navigationItem.scrollEdgeAppearance = appearance

        func copyAction(_ content: TranslationViewModel.TranscriptContent, title: String, icon: String) -> UIAction {
            UIAction(title: title, image: UIImage(systemName: icon)) { [weak self] _ in
                guard let self else { return }
                self.copy(self.viewModel.transcript(content))
            }
        }

        let newConversation = UIAction(title: String(localized: "New"), image: UIImage(systemName: "doc.badge.plus")) { [weak self] _ in
            self?.viewModel.clear()
        }
        let load = UIAction(title: String(localized: "Load"), image: UIImage(systemName: "folder")) { [weak self] _ in
            self?.chooseConversationFile()
        }
        let save = UIAction(title: String(localized: "Save"), image: UIImage(systemName: "square.and.arrow.down")) { [weak self] _ in
            self?.saveConversation()
        }
        let apiKey = UIAction(title: String(localized: "Inworld API Key"), image: UIImage(systemName: "key")) { [weak self] _ in
            self?.openAPIKeySettings()
        }
        let voice = UIAction(title: String(localized: "Voice"), image: UIImage(systemName: "waveform")) { [weak self] _ in
            self?.openVoiceSettings()
        }
        let speed = UIAction(title: String(localized: "Speed"), image: UIImage(systemName: "speedometer")) { [weak self] _ in
            self?.openSpeedSettings()
        }
        let conversation = UIMenu(options: .displayInline, children: [newConversation, load, save])
        let copy = UIMenu(options: .displayInline, children: [
            copyAction(.original, title: String(localized: "Copy Original"), icon: "text.quote"),
            copyAction(.translation, title: String(localized: "Copy Translation"), icon: "doc.on.doc"),
            copyAction(.both, title: String(localized: "Copy Both"), icon: "doc.on.clipboard"),
        ])
        let settings = UIMenu(options: .displayInline, children: [apiKey, voice, speed])
        let more = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), menu: UIMenu(children: [conversation, copy, settings]))
        more.preferredMenuElementOrder = .fixed
        more.accessibilityLabel = String(localized: "More")
        navigationItem.rightBarButtonItem = more

        guard let pictureInPicture else { return }
        let pictureButton = UIBarButtonItem(image: AVPictureInPictureController.pictureInPictureButtonStartImage, primaryAction: UIAction { [weak self] _ in
            guard let self, let pictureInPicture = self.pictureInPicture else { return }
            self.updatePictureInPicture(pictureInPicture)
            pictureInPicture.toggle()
        })
        pictureButton.accessibilityLabel = String(localized: "Start Picture in Picture")
        pictureButton.isEnabled = false
        pictureInPictureButton = pictureButton
        navigationItem.rightBarButtonItems = [more, pictureButton]
        pictureInPicture.onStateChanged = { [weak self] in self?.renderPictureInPictureButton() }
        pictureInPicture.onStartFailed = { [weak self] in
            guard let self, self.view.window?.windowScene?.activationState == .foregroundActive,
                  self.presentedViewController == nil else { return }
            self.showAlert(String(localized: "Picture in Picture Unavailable"), message: String(localized: "iOS couldn’t open the floating caption window."))
        }
    }

    func configureHeader() {
        configureLanguageButton(sourceButton, mode: .source)
        configureLanguageButton(targetButton, mode: .target)
        bidirectionalButton.accessibilityLabel = String(localized: "Bidirectional translation")
        bidirectionalButton.addAction(UIAction { [weak self] _ in
            self?.viewModel.toggleBidirectional()
        }, for: .primaryActionTriggered)
    }

    func configureLanguageButton(_ button: UIButton, mode: LanguagePickerViewController.Mode) {
        let fill = mode == .source ? TranslationTheme.original : TranslationTheme.translated
        button.configuration = TranslationTheme.pill(fill: fill, foreground: TranslationTheme.accent)
        button.configuration?.buttonSize = .small
        button.configuration?.titleLineBreakMode = .byTruncatingTail
        button.configuration?.image = UIImage(systemName: "chevron.down")
        button.configuration?.imagePlacement = .trailing
        button.configuration?.imagePadding = 6
        button.titleLabel?.numberOfLines = 1
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.titleLabel?.minimumScaleFactor = 0.6
        button.configurationUpdateHandler = { button in
            guard var configuration = button.configuration else { return }
            let textColor = button.isEnabled ? TranslationTheme.accent : TranslationTheme.secondaryText
            configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var attributes = attributes
                attributes.font = TranslationTheme.rounded(.preferredFont(forTextStyle: .subheadline))
                attributes.foregroundColor = textColor
                return attributes
            }
            configuration.imageColorTransformer = UIConfigurationColorTransformer { _ in textColor }
            button.configuration = configuration
        }
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

    func configureTable() {
        tableView.register(PhraseCell.self, forCellReuseIdentifier: PhraseCell.reuseIdentifier)
        tableView.delegate = self
        tableView.allowsSelection = false
        tableView.backgroundColor = TranslationTheme.canvas
        tableView.separatorStyle = .none
        tableView.contentInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
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
    }

    func configureNotice() {
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

    func configureButtons() {
        var start = UIButton.Configuration.filled()
        start.cornerStyle = .capsule
        start.buttonSize = .large
        start.imagePadding = 8
        start.baseForegroundColor = .white
        start.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = TranslationTheme.rounded(.preferredFont(forTextStyle: .headline))
            return attributes
        }
        startButton.configuration = start
        startButton.configurationUpdateHandler = { button in
            guard var configuration = button.configuration else { return }
            if configuration.baseBackgroundColor == TranslationTheme.primary, !button.isHighlighted {
                configuration.background.image = TranslationTheme.startBackground
            } else {
                configuration.background.image = nil
            }
            button.configuration = configuration
        }
        startButton.translatesAutoresizingMaskIntoConstraints = false
        startButton.addAction(UIAction { [weak self] _ in self?.viewModel.toggle() }, for: .primaryActionTriggered)

        speakButton.translatesAutoresizingMaskIntoConstraints = false
        speakButton.accessibilityLabel = String(localized: "Speak Translations")
        speakButton.accessibilityHint = String(localized: "Reads translations aloud. Listening continues on supported headphone routes.")
        speakButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.viewModel.setSpeaksTranslations(!self.viewModel.speaksTranslations)
        }, for: .primaryActionTriggered)

        var jump = TranslationTheme.pill(fill: TranslationTheme.translated, foreground: TranslationTheme.accent)
        jump.buttonSize = .large
        jump.title = String(localized: "Jump to Latest")
        jump.image = UIImage(systemName: "forward.end.fill")
        jump.imagePadding = 8
        jumpButton.configuration = jump
        jumpButton.accessibilityHint = String(localized: "Skips translations waiting to be spoken.")
        jumpButton.isHidden = true
        jumpButton.translatesAutoresizingMaskIntoConstraints = false
        jumpButton.addAction(UIAction { [weak self] _ in
            self?.viewModel.jumpToLatestSpeech()
        }, for: .primaryActionTriggered)
    }
}
