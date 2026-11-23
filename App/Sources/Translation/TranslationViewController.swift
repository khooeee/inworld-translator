import AVKit
import TranslatorCore
import UIKit
import UniformTypeIdentifiers

/// Language choices above the conversation, with listening controls,
/// connection status, and microphone level at the bottom.
final class TranslationViewController: UIViewController {
    let viewModel: TranslationViewModel
    let openAPIKeySettings: () -> Void
    let openVoiceSettings: () -> Void
    let openSpeedSettings: () -> Void

    let statusView = ConnectionStatusView()
    let levelMeter = LevelMeterView()
    let sourceButton = UIButton(configuration: .tinted())
    let targetButton = UIButton(configuration: .tinted())
    let bidirectionalButton = UIButton(configuration: .gray())
    let tableView = UITableView(frame: .zero, style: .plain)
    let emptyView = TranslationEmptyView()
    let noticeView = NoticeView()
    let jumpButton = UIButton(configuration: .filled())
    let startButton = UIButton(configuration: .filled())
    let speakButton = UIButton(configuration: .gray())
    let pictureInPicture = CaptionPictureInPicture.makeIfSupported()
    var pictureInPictureButton: UIBarButtonItem?

    var dataSource: UITableViewDiffableDataSource<Int, PhraseID>!
    var pendingExport: URL?
    /// Whether new captions should scroll into view: true until the user
    /// scrolls up to read earlier ones.
    var followsLatest = true

    init(
        viewModel: TranslationViewModel,
        openAPIKeySettings: @escaping () -> Void,
        openVoiceSettings: @escaping () -> Void,
        openSpeedSettings: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        self.openAPIKeySettings = openAPIKeySettings
        self.openVoiceSettings = openVoiceSettings
        self.openSpeedSettings = openSpeedSettings
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
        view.backgroundColor = TranslationTheme.canvas
        configureNavigationItems()
        configureHeader()
        configureTable()
        configureNotice()
        configureButtons()
        layout()
        bindViewModel()
    }
}
