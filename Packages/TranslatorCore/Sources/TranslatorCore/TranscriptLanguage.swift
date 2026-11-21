import NaturalLanguage

enum TranscriptLanguage {
    /// Resolve clear phrases locally. Inworld can decide cases where the
    /// selected languages are hard to distinguish from the transcript alone.
    static func source(in text: String, between first: TranslationLanguage, and second: TranslationLanguage) -> TranslationLanguage? {
        let pair = Set([first, second])
        // Chinese script predictions do not reliably distinguish this pair.
        guard pair != Set([.chinese, .cantonese]) else { return nil }

        let hypotheses = hypotheses(for: text)
        guard let top = hypotheses.max(by: { $0.value < $1.value }),
              let source = pair.first(where: { $0.matches(top.key.rawValue) }) else { return nil }
        let other = source == first ? second : first
        let otherScore = hypotheses.filter { other.matches($0.key.rawValue) }.values.max() ?? 0
        // Short phrases can have a low absolute score while strongly favoring
        // one member of the selected pair, especially across scripts.
        guard top.value >= 0.55 || (top.value >= 0.12 && top.value >= 4 * otherScore) else { return nil }
        return source
    }

    static func clearlyMatches(_ language: TranslationLanguage, text: String) -> Bool {
        // Leave short names, numbers, and borrowed expressions alone.
        guard text.filter(\.isLetter).count >= 6,
              let top = hypotheses(for: text).max(by: { $0.value < $1.value }) else { return false }
        return top.value >= 0.85 && language.matches(top.key.rawValue)
    }

    private static func hypotheses(for text: String) -> [NLLanguage: Double] {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.languageHypotheses(withMaximum: 8)
    }
}
