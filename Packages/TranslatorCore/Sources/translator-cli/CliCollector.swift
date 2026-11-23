import Foundation
import TranslatorCore

final class Collector: @unchecked Sendable {
    // Touched only from the single consumer task below.
    var phrases: [PhraseID: Phrase] = [:]
    var statuses: [(Date, SessionStatus)] = []
    var notices: [SessionNotice] = []
    var printed: Set<PhraseID> = []
    var spoken: [PhraseID] = []
    var speaking: PhraseID?
    /// When each phrase started to be spoken, in order.
    var speechStarts: [(PhraseID, Date)] = []

    // Ordering and stability, checked as events arrive.
    var newestID: PhraseID?
    var outOfOrder = 0
    var changedAfterSettling = 0
    var reopened = 0

    func check(_ phrase: Phrase) {
        guard let previous = phrases[phrase.id] else {
            if let newestID, phrase.id < newestID { outOfOrder += 1 }
            newestID = phrase.id
            return
        }
        if previous.isSettled, (previous.sourceText, previous.translation) != (phrase.sourceText, phrase.translation) {
            changedAfterSettling += 1
        }
        if previous.sourceState != .provisional, phrase.sourceState == .provisional {
            reopened += 1
        }
    }
}
