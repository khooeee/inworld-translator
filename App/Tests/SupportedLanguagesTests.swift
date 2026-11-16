import Foundation
import Testing
@testable import InworldTranslator

@MainActor
@Suite struct SupportedLanguagesTests {
    @Test func listsInworldsThirtyLanguagesOnce() {
        let codes = SupportedLanguagesViewController.codes
        #expect(codes.count == 30)
        #expect(Set(codes).count == codes.count)
    }

    @Test func everyLanguageHasAName() {
        let languages = SupportedLanguagesViewController.languages(in: Locale(identifier: "en_US"))
        for language in languages {
            #expect(language.name != language.code, "no English name for \(language.code)")
            #expect(language.nativeName != language.code, "no native name for \(language.code)")
        }
        #expect(languages.map(\.name) == languages.map(\.name).sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        #expect(languages.first { $0.code == "ja" }?.nativeName == "日本語")
    }
}
