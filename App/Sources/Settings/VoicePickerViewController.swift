import AVFAudio
import TranslatorCore
import UIKit

final class VoicePickerViewController: UITableViewController, UISearchResultsUpdating {
    private typealias Voice = InworldClient.Voice

    private enum CatalogState {
        case loading
        case loaded
        case failed(ServiceError?)
    }

    private let client: InworldClient
    private let preference: SpeechVoicePreference
    private let canPreview: () -> Bool
    private let search = UISearchController(searchResultsController: nil)
    private let previewCache = NSCache<NSString, NSData>()
    private var catalogState = CatalogState.loading
    private var voices: [Voice] = []
    private var visibleVoices: [Voice] = []
    private var catalogTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var previewVoiceID: Voice.ID?
    private var player: AVAudioPlayer?

    init(client: InworldClient, preference: SpeechVoicePreference, canPreview: @escaping () -> Bool) {
        self.client = client
        self.preference = preference
        self.canPreview = canPreview
        super.init(style: .insetGrouped)
        previewCache.totalCostLimit = 8 * 1024 * 1024
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        catalogTask?.cancel()
        previewTask?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Voice")
        navigationItem.largeTitleDisplayMode = .never
        search.searchBar.placeholder = String(localized: "Search voices")
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.hidesNavigationBarDuringPresentation = false
        definesPresentationContext = true
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Voice")
        loadVoices()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopPreview()
    }

    private func loadVoices() {
        guard catalogTask == nil else { return }
        catalogState = .loading
        renderCatalog()
        catalogTask = Task { [weak self, client] in
            do {
                let voices = try await client.listVoices()
                guard let self, !Task.isCancelled else { return }
                self.voices = voices
                self.catalogState = .loaded
                self.catalogTask = nil
                self.renderCatalog()
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.catalogState = .failed(error as? ServiceError)
                self.catalogTask = nil
                self.renderCatalog()
            }
        }
    }

    func updateSearchResults(for searchController: UISearchController) {
        renderCatalog()
    }

    private func renderCatalog() {
        let query = search.searchBar.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        visibleVoices = query.isEmpty ? voices : voices.filter { voice in
            voice.name.localizedStandardContains(query) || Self.languageName(for: voice)?.localizedStandardContains(query) == true
        }
        switch catalogState {
        case .loading:
            var configuration = UIContentUnavailableConfiguration.loading()
            configuration.text = String(localized: "Loading voices…")
            contentUnavailableConfiguration = configuration
        case .loaded where voices.isEmpty:
            var configuration = UIContentUnavailableConfiguration.empty()
            configuration.text = String(localized: "No Voices Available")
            configuration.secondaryText = String(localized: "Inworld returned no voices for this API key.")
            contentUnavailableConfiguration = configuration
        case .loaded:
            contentUnavailableConfiguration = visibleVoices.isEmpty ? UIContentUnavailableConfiguration.search() : nil
        case .failed(let error):
            var configuration = UIContentUnavailableConfiguration.empty()
            configuration.text = String(localized: "Couldn’t Load Voices")
            switch error {
            case .some(.notConfigured):
                configuration.secondaryText = String(localized: "Add your Inworld API key from the Translator menu.")
            case .some(.unauthorized):
                configuration.secondaryText = String(localized: "Check your Inworld API key and its read permissions.")
            default:
                configuration.secondaryText = String(localized: "Check your connection and try again.")
            }
            configuration.button = .bordered()
            configuration.button.title = String(localized: "Try Again")
            configuration.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.loadVoices() }
            contentUnavailableConfiguration = configuration
        }
        tableView.reloadData()
    }

    private static func languageName(for voice: Voice) -> String? {
        voice.languageCode.flatMap { Locale.current.localizedString(forIdentifier: $0) }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        visibleVoices.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Voice", for: indexPath)
        let voice = visibleVoices[indexPath.row]
        let isSelected = voice.id == preference.id
        let isPreviewing = voice.id == previewVoiceID

        var content = UIListContentConfiguration.subtitleCell()
        content.text = voice.name
        content.secondaryText = Self.languageName(for: voice)
        cell.contentConfiguration = content
        cell.accessoryView = makeAccessory(for: voice, isSelected: isSelected, isPreviewing: isPreviewing)
        if isSelected {
            cell.accessibilityTraits.insert(.selected)
        } else {
            cell.accessibilityTraits.remove(.selected)
        }
        let actionName = isPreviewing
            ? String(localized: "Stop preview for \(voice.name)")
            : String(localized: "Preview \(voice.name)")
        cell.accessibilityCustomActions = [UIAccessibilityCustomAction(name: actionName) { [weak self] _ in
            self?.togglePreview(of: voice)
            return true
        }]
        return cell
    }

    private func makeAccessory(for voice: Voice, isSelected: Bool, isPreviewing: Bool) -> UIView {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: isPreviewing ? "stop.circle.fill" : "play.circle",
                                      withConfiguration: UIImage.SymbolConfiguration(pointSize: 23))
        configuration.contentInsets = .zero
        let preview = UIButton(configuration: configuration)
        preview.isAccessibilityElement = false
        preview.addAction(UIAction { [weak self] _ in self?.togglePreview(of: voice) }, for: .primaryActionTriggered)

        let checkmark = UIImageView(image: UIImage(systemName: "checkmark"))
        checkmark.contentMode = .scaleAspectFit
        checkmark.isHidden = !isSelected
        let accessory = UIStackView(arrangedSubviews: [checkmark, preview])
        accessory.alignment = .center
        accessory.spacing = 6
        accessory.frame = CGRect(x: 0, y: 0, width: isSelected ? 70 : 44, height: 44)
        NSLayoutConstraint.activate([
            preview.heightAnchor.constraint(equalToConstant: 44),
            preview.widthAnchor.constraint(equalToConstant: 44),
        ])
        return accessory
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        preference.select(visibleVoices[indexPath.row].id)
        tableView.deselectRow(at: indexPath, animated: true)
        tableView.reloadData()
    }

    private func togglePreview(of voice: Voice) {
        if previewVoiceID == voice.id {
            stopPreview()
            return
        }
        guard canPreview() else {
            showPreviewAlert(String(localized: "Stop listening before playing a voice preview."))
            return
        }
        stopPreview()
        previewVoiceID = voice.id
        tableView.reloadData()
        let cached = previewCache.object(forKey: voice.id as NSString) as Data?
        previewTask = Task { [weak self, client] in
            do {
                let data: Data
                if let cached {
                    data = cached
                } else {
                    data = try await client.voicePreview(id: voice.id)
                }
                guard let self, !Task.isCancelled else { return }
                self.previewTask = nil
                guard self.canPreview() else {
                    self.stopPreview()
                    return
                }
                try self.play(data)
                self.previewCache.setObject(data as NSData, forKey: voice.id as NSString, cost: data.count)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.stopPreview()
                self.showPreviewAlert(String(localized: "Try this voice again or choose another voice."))
            }
        }
    }

    private func play(_ data: Data) throws {
        let player = try AVAudioPlayer(data: data)
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.playback, mode: .default, options: .mixWithOthers)
        try audio.setActive(true)
        self.player = player
        player.delegate = self
        guard player.play() else { throw ServiceError.invalidResponse }
    }

    private func stopPreview() {
        guard previewVoiceID != nil else { return }
        previewVoiceID = nil
        previewTask?.cancel()
        previewTask = nil
        if let player {
            player.stop()
            self.player = nil
            if canPreview() {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
        tableView.reloadData()
    }

    private func showPreviewAlert(_ message: String) {
        let presenter: UIViewController = presentedViewController === search ? search : self
        guard presenter.viewIfLoaded?.window != nil, presenter.presentedViewController == nil else { return }
        let alert = UIAlertController(title: String(localized: "Voice Preview Unavailable"), message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
        presenter.present(alert, animated: true)
    }
}

extension VoicePickerViewController: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let finishedPlayerID = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, let currentPlayer = self.player, ObjectIdentifier(currentPlayer) == finishedPlayerID else { return }
            self.stopPreview()
            if !flag { self.showPreviewAlert(String(localized: "Try this voice again or choose another voice.")) }
        }
    }
}
