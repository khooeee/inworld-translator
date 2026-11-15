import UIKit

/// Where the user pastes their Inworld API key. The key is checked against
/// Inworld before it is saved to the Keychain.
final class APIKeyViewController: UIViewController {
    private let store: APIKeyStore
    private let baseURL: URL
    private let onSaved: () -> Void

    private let explanation = UILabel()
    private let field = UITextField()
    private let statusLabel = UILabel()
    private let saveButton = UIButton(configuration: .filled())
    private let removeButton = UIButton(configuration: .plain())
    private let portalButton = UIButton(configuration: .plain())
    private var check: Task<Void, Never>?

    init(store: APIKeyStore, baseURL: URL, onSaved: @escaping () -> Void) {
        self.store = store
        self.baseURL = baseURL
        self.onSaved = onSaved
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Inworld API Key")
        view.backgroundColor = .systemGroupedBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })

        explanation.text = String(localized: "Paste the Base64 credentials from Inworld Portal → API Keys. The key is stored in this device's Keychain and sent only to Inworld. Usage is billed to your Inworld account.")
        explanation.font = .preferredFont(forTextStyle: .body)
        explanation.adjustsFontForContentSizeCategory = true
        explanation.numberOfLines = 0
        explanation.textColor = .secondaryLabel

        field.placeholder = store.hasKey ? String(localized: "A key is saved. Paste a new one to replace it.") : String(localized: "API key")
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.borderStyle = .roundedRect
        field.isSecureTextEntry = true
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.textContentType = .password
        field.returnKeyType = .done
        field.clearButtonMode = .whileEditing
        field.accessibilityLabel = String(localized: "API key")
        field.addAction(UIAction { [weak self] _ in self?.updateSaveButton() }, for: .editingChanged)
        field.addAction(UIAction { [weak self] _ in self?.save() }, for: .editingDidEndOnExit)

        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.numberOfLines = 0

        var save = UIButton.Configuration.filled()
        save.title = String(localized: "Check and Save")
        save.cornerStyle = .large
        save.buttonSize = .large
        saveButton.configuration = save
        saveButton.addAction(UIAction { [weak self] _ in self?.save() }, for: .primaryActionTriggered)

        var remove = UIButton.Configuration.plain()
        remove.title = String(localized: "Remove Saved Key")
        remove.baseForegroundColor = .systemRed
        removeButton.configuration = remove
        removeButton.isHidden = !store.hasKey
        removeButton.addAction(UIAction { [weak self] _ in self?.remove() }, for: .primaryActionTriggered)

        var portal = UIButton.Configuration.plain()
        portal.title = String(localized: "Open Inworld Portal")
        portal.image = UIImage(systemName: "arrow.up.right.square")
        portal.imagePadding = 6
        portalButton.configuration = portal
        portalButton.addAction(UIAction { _ in
            if let url = URL(string: "https://platform.inworld.ai/api-keys") {
                UIApplication.shared.open(url)
            }
        }, for: .primaryActionTriggered)

        for button in [saveButton, removeButton, portalButton] {
            button.titleLabel?.adjustsFontForContentSizeCategory = true
        }

        let stack = UIStackView(arrangedSubviews: [explanation, field, statusLabel, saveButton, portalButton, removeButton])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = UIScrollView()
        scroll.alwaysBounceVertical = true
        scroll.keyboardDismissMode = .interactive
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.leadingAnchor.constraint(equalTo: view.readableContentGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.readableContentGuide.trailingAnchor),
            field.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        updateSaveButton()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        field.becomeFirstResponder()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        check?.cancel()
    }

    private var enteredKey: String {
        (field.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func updateSaveButton() {
        saveButton.isEnabled = !enteredKey.isEmpty && check == nil
    }

    private func show(_ message: String, color: UIColor) {
        statusLabel.text = message
        statusLabel.textColor = color
        UIAccessibility.post(notification: .announcement, argument: message)
    }

    private func save() {
        let key = enteredKey
        guard !key.isEmpty, check == nil else { return }
        field.resignFirstResponder()
        show(String(localized: "Checking the key with Inworld…"), color: .secondaryLabel)
        check = Task { [weak self, baseURL] in
            let result = await Self.verify(key: key, baseURL: baseURL)
            guard let self, !Task.isCancelled else { return }
            self.check = nil
            self.updateSaveButton()
            switch result {
            case .rejected:
                self.show(String(localized: "Inworld didn't accept this key. Copy it again from the Portal."), color: .systemRed)
                return
            case .accepted, .unverified:
                do {
                    try self.store.save(key)
                } catch {
                    self.show(error.localizedDescription, color: .systemRed)
                    return
                }
                self.onSaved()
                if result == .unverified {
                    // Offline: keep the key, but say it is unchecked.
                    self.show(String(localized: "Saved. Inworld couldn't be reached to check it."), color: .systemOrange)
                    self.field.text = nil
                    self.removeButton.isHidden = false
                } else {
                    self.dismiss(animated: true)
                }
            }
        }
        updateSaveButton()
    }

    private func remove() {
        do {
            try store.delete()
            removeButton.isHidden = true
            field.placeholder = String(localized: "API key")
            show(String(localized: "The key was removed from this device."), color: .secondaryLabel)
            onSaved()
        } catch {
            show(error.localizedDescription, color: .systemRed)
        }
    }

    enum Verification: Equatable {
        case accepted
        case rejected
        case unverified
    }

    /// Lists one model with the key: free, and fails with 401 for a bad key.
    nonisolated static func verify(key: String, baseURL: URL) async -> Verification {
        var components = URLComponents(url: baseURL.appendingPathComponent("llm/v1alpha/models"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "provider", value: "google-ai-studio"),
            URLQueryItem(name: "model", value: "gemini-2.5-flash-lite"),
        ]
        guard let url = components?.url else { return .unverified }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("Basic \(key)", forHTTPHeaderField: "Authorization")
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode
        else { return .unverified }
        switch status {
        case 200: return .accepted
        case 401, 403: return .rejected
        default: return .unverified
        }
    }
}
