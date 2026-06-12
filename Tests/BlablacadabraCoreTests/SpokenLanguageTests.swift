import Testing
@testable import BlablacadabraCore

@Suite struct SpokenLanguageTests {
    @Test func mapsCommonCodes() {
        #expect(SpokenLanguage.displayName(forCode: "id") == "Indonesian")
        #expect(SpokenLanguage.displayName(forCode: "de") == "German")
        #expect(SpokenLanguage.displayName(forCode: "ja") == "Japanese")
        #expect(SpokenLanguage.displayName(forCode: "yue") == "Cantonese")
    }

    @Test func isCaseInsensitive() {
        #expect(SpokenLanguage.displayName(forCode: "ID") == "Indonesian")
        #expect(SpokenLanguage.displayName(forCode: "De") == "German")
    }

    @Test func returnsNilForUnknownOrEmpty() {
        #expect(SpokenLanguage.displayName(forCode: nil) == nil)
        #expect(SpokenLanguage.displayName(forCode: "") == nil)
        #expect(SpokenLanguage.displayName(forCode: "zz") == nil)
    }

    @Test func englishStillResolves() {
        // The map knows "en"; the status layer decides when to show it.
        #expect(SpokenLanguage.displayName(forCode: "en") == "English")
    }
}
