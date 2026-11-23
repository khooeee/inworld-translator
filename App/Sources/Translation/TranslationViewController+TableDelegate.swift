import AVKit
import TranslatorCore
import UIKit
import UniformTypeIdentifiers

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
    func updateFollowing(_ scrollView: UIScrollView) {
        let distanceFromBottom = scrollView.contentSize.height - scrollView.contentOffset.y - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
        followsLatest = distanceFromBottom < 40
    }

    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard let id = dataSource.itemIdentifier(for: indexPath), let phrase = viewModel.phrase(for: id) else { return nil }
        let configuration = UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            var actions = [
                UIAction(title: String(localized: "Copy Original"), image: UIImage(systemName: "text.quote")) { _ in self?.copy(phrase.sourceText) },
            ]
            if let translation = phrase.translatedText, !phrase.isSpokenInTargetLanguage {
                actions.append(UIAction(title: String(localized: "Copy Translation"), image: UIImage(systemName: "doc.on.doc")) { _ in self?.copy(translation) })
                actions.append(UIAction(title: String(localized: "Copy Both"), image: UIImage(systemName: "doc.on.clipboard")) { _ in
                    self?.copy(TranslationViewModel.text(for: phrase))
                })
            }
            return UIMenu(children: actions)
        }
        configuration.preferredMenuElementOrder = .fixed
        return configuration
    }
}
