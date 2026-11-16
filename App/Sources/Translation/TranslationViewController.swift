import TranslatorCore
import UIKit

/// The one screen: connection status and microphone level at the top, the
/// conversation in the middle, and Start/Stop at the bottom.
final class TranslationViewController: UIViewController {
    private let viewModel: TranslationViewModel
    private let openAPIKeySettings: () -> Void

    private let statusView = ConnectionStatusView()
    private let levelMeter = LevelMeterView()
    private let headerStack = UIStackView()
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let emptyLabel = UILabel()
    private let noticeView = NoticeView()
    private let jumpButton = UIButton(configuration: .filled())
    private let startButton = UIButton(configuration: .filled())

    private var dataSource: UITableViewDiffableDataSource<Int, PhraseID>!
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
        let copyAll = UIAction(title: String(localized: "Copy Conversation"), image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
            guard let self else { return }
            self.copy(self.viewModel.transcript())
        }
        let clear = UIAction(title: String(localized: "Clear Conversation"), image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
            self?.viewModel.clear()
        }
        let languages = UIAction(title: String(localized: "Supported Languages"), image: UIImage(systemName: "globe")) { [weak self] _ in
            self?.navigationController?.pushViewController(SupportedLanguagesViewController(), animated: true)
        }
        let conversation = UIMenu(options: .displayInline, children: [copyAll, clear])
        let more = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), menu: UIMenu(children: [conversation, languages]))
        more.accessibilityLabel = String(localized: "More")
        let settings = UIBarButtonItem(image: UIImage(systemName: "key"), primaryAction: UIAction { [weak self] _ in
            self?.openAPIKeySettings()
        })
        settings.accessibilityLabel = String(localized: "API key")
        navigationItem.rightBarButtonItems = [more, settings]
    }

    private func configureHeader() {
        headerStack.addArrangedSubview(statusView)
        headerStack.addArrangedSubview(levelMeter)
        headerStack.spacing = 12
        headerStack.alignment = .center
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        levelMeter.widthAnchor.constraint(equalToConstant: 96).isActive = true
        updateHeaderAxis()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _) in
            self.updateHeaderAxis()
        }
    }

    /// At accessibility text sizes the status needs the full width.
    private func updateHeaderAxis() {
        let large = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        headerStack.axis = large ? .vertical : .horizontal
        headerStack.alignment = large ? .leading : .center
    }

    private func configureTable() {
        tableView.register(PhraseCell.self, forCellReuseIdentifier: PhraseCell.reuseIdentifier)
        tableView.delegate = self
        tableView.allowsSelection = false
        tableView.keyboardDismissMode = .onDrag
        tableView.translatesAutoresizingMaskIntoConstraints = false

        dataSource = UITableViewDiffableDataSource(tableView: tableView) { [weak self] tableView, indexPath, id in
            let cell = tableView.dequeueReusableCell(withIdentifier: PhraseCell.reuseIdentifier, for: indexPath) as! PhraseCell
            if let phrase = self?.viewModel.phrase(for: id) {
                cell.configure(with: phrase)
            }
            cell.onCopy = { [weak self] text in self?.copy(text) }
            return cell
        }
        dataSource.defaultRowAnimation = .fade

        emptyLabel.text = String(localized: "Tap Start and let people speak in any language. English captions appear here.")
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

        var jump = UIButton.Configuration.filled()
        jump.cornerStyle = .capsule
        jump.buttonSize = .small
        jump.title = String(localized: "Jump to Latest")
        jump.image = UIImage(systemName: "arrow.down")
        jump.imagePadding = 4
        jump.baseBackgroundColor = .secondarySystemFill
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
        let bottomStack = UIStackView(arrangedSubviews: [noticeView, startButton])
        bottomStack.axis = .vertical
        bottomStack.spacing = 12
        bottomStack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(headerStack)
        view.addSubview(tableView)
        view.addSubview(jumpButton)
        view.addSubview(bottomStack)

        let margins = view.layoutMarginsGuide
        let readable = view.readableContentGuide
        NSLayoutConstraint.activate([
            headerStack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            headerStack.leadingAnchor.constraint(equalTo: readable.leadingAnchor),
            headerStack.trailingAnchor.constraint(lessThanOrEqualTo: readable.trailingAnchor),

            tableView.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 8),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: bottomStack.topAnchor, constant: -8),

            jumpButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            jumpButton.bottomAnchor.constraint(equalTo: tableView.bottomAnchor, constant: -12),

            bottomStack.leadingAnchor.constraint(equalTo: readable.leadingAnchor),
            bottomStack.trailingAnchor.constraint(equalTo: readable.trailingAnchor),
            bottomStack.bottomAnchor.constraint(equalTo: margins.bottomAnchor, constant: -8),
            startButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 56),
        ])
        tableView.cellLayoutMarginsFollowReadableWidth = true
    }

    // MARK: View model

    private func bindViewModel() {
        viewModel.onPhrasesChanged = { [weak self] changes in self?.apply(changes) }
        viewModel.onStatusChanged = { [weak self] status in self?.render(status: status) }
        viewModel.onLevelChanged = { [weak self] level in self?.levelMeter.set(level: level) }
        viewModel.onNoticeChanged = { [weak self] notice in self?.render(notice: notice) }
        viewModel.onTranslationCompleted = { phrase in
            guard UIAccessibility.isVoiceOverRunning, let english = phrase.english, !phrase.isSpokenInEnglish else { return }
            // Queued, so a new caption never cuts off the one being read.
            let announcement = NSAttributedString(string: english, attributes: [.accessibilitySpeechQueueAnnouncement: true])
            UIAccessibility.post(notification: .announcement, argument: announcement)
        }

        // Show whatever happened before the view loaded, such as a notice from
        // starting at launch.
        render(status: viewModel.status)
        render(notice: viewModel.notice)
        apply(TranslationViewModel.PhraseChanges(inserted: viewModel.phrases.map(\.id)))
    }

    private func apply(_ changes: TranslationViewModel.PhraseChanges) {
        var snapshot = dataSource.snapshot()
        if snapshot.numberOfSections == 0 {
            snapshot.appendSections([0])
        }
        let present = Set(snapshot.itemIdentifiers)
        let removed = changes.removed.filter(present.contains)
        if !removed.isEmpty {
            snapshot.deleteItems(removed)
        }
        let inserted = changes.inserted.filter { !present.contains($0) }
        for id in inserted {
            // Phrases are kept in order by the view model; mirror its order.
            let following = viewModel.phrases.first { $0.id > id && snapshot.indexOfItem($0.id) != nil }
            if let following {
                snapshot.insertItems([id], beforeItem: following.id)
            } else {
                snapshot.appendItems([id])
            }
        }
        let updated = changes.updated.filter(present.contains)
        if !updated.isEmpty {
            snapshot.reconfigureItems(updated)
        }

        let follow = followsLatest
        // Revisions arrive many times a second; animating each one makes the
        // list shimmer, so only insertions and removals animate.
        let animate = !(inserted.isEmpty && removed.isEmpty) && !UIAccessibility.isReduceMotionEnabled
        dataSource.apply(snapshot, animatingDifferences: animate) { [weak self] in
            guard let self else { return }
            if follow {
                self.scrollToLatest(animated: animate)
            } else if !inserted.isEmpty {
                self.jumpButton.isHidden = false
            }
            self.updateEmptyState()
        }
    }

    private func render(status: SessionStatus) {
        statusView.show(status)
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
            startButton.accessibilityHint = String(localized: "Listens to speech in any language and translates it into English.")
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
            if let english = phrase.english, !phrase.isSpokenInEnglish {
                actions.append(UIAction(title: String(localized: "Copy English"), image: UIImage(systemName: "doc.on.doc")) { _ in self?.copy(english) })
            }
            actions.append(UIAction(title: String(localized: "Copy Original"), image: UIImage(systemName: "text.quote")) { _ in self?.copy(phrase.sourceText) })
            if phrase.english != nil, !phrase.isSpokenInEnglish {
                actions.append(UIAction(title: String(localized: "Copy Both"), image: UIImage(systemName: "doc.on.clipboard")) { _ in
                    self?.copy(TranslationViewModel.text(for: phrase))
                })
            }
            return UIMenu(children: actions)
        }
    }
}
