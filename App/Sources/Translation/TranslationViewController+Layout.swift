import AVKit
import TranslatorCore
import UIKit
import UniformTypeIdentifiers

extension TranslationViewController {
    func layout() {
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

        if let source = pictureInPicture?.sourceView {
            source.translatesAutoresizingMaskIntoConstraints = false
            view.insertSubview(source, belowSubview: tableView)
            let preferredWidth = source.widthAnchor.constraint(equalTo: readable.widthAnchor)
            preferredWidth.priority = .defaultHigh
            NSLayoutConstraint.activate([
                source.centerXAnchor.constraint(equalTo: readable.centerXAnchor),
                source.centerYAnchor.constraint(equalTo: tableView.centerYAnchor),
                source.widthAnchor.constraint(lessThanOrEqualTo: readable.widthAnchor),
                source.heightAnchor.constraint(lessThanOrEqualTo: tableView.heightAnchor),
                source.widthAnchor.constraint(equalTo: source.heightAnchor, multiplier: CaptionFrame.aspectRatio),
                preferredWidth,
            ])
        }
    }
}
