import Testing
@testable import BlablacadabraCore

@Suite struct SpellingNormalizerTests {
    @Test func usIsIdentity() {
        let normalizer = SpellingNormalizer(locale: .us)
        #expect(normalizer.isIdentity)
        let line = "My favorite color is gray, I realize that now."
        #expect(normalizer.normalize(line) == line)
    }

    @Test func ukConvertsSpellingAndIseVerbs() {
        let normalizer = SpellingNormalizer(locale: .uk)
        #expect(
            normalizer.normalize("My favorite color is gray, I realize that now.")
                == "My favourite colour is grey, I realise that now."
        )
        #expect(
            normalizer.normalize("The theater in the city center was canceled.")
                == "The theatre in the city centre was cancelled."
        )
    }

    @Test func canadaKeepsIzeButTakesBritishSpelling() {
        let normalizer = SpellingNormalizer(locale: .ca)
        #expect(
            normalizer.normalize("I realize the color of my neighbor's armor.")
                == "I realize the colour of my neighbour's armour."
        )
        #expect(normalizer.normalize("defense") == "defence")
    }

    @Test func sharedBritishLocalesMatchUK() {
        let line = "Organize the colorful catalog at the center."
        let uk = SpellingNormalizer(locale: .uk).normalize(line)
        for locale in [EnglishLocale.au, .sg, .india, .nz, .ie] {
            #expect(SpellingNormalizer(locale: locale).normalize(line) == uk)
        }
        #expect(uk == "Organise the colourful catalogue at the centre.")
    }

    @Test func casingIsPreserved() {
        let normalizer = SpellingNormalizer(locale: .uk)
        #expect(normalizer.normalize("Color COLOR color") == "Colour COLOUR colour")
    }

    @Test func ambiguousAndUnrelatedWordsAreLeftAlone() {
        let normalizer = SpellingNormalizer(locale: .uk)
        // Whole words only: no substring rewrites inside other words.
        #expect(normalizer.normalize("Singapore decor watercolors") == "Singapore decor watercolors")
        // Words whose US form doubles as a different valid word stay put.
        #expect(
            normalizer.normalize("Check the parking meter, the program tires me.")
                == "Check the parking meter, the program tires me."
        )
        // Size and prize never become sise/prise (curated dict, no suffix rules).
        #expect(normalizer.normalize("The prize size") == "The prize size")
    }

    @Test func punctuationAndApostrophesSurvive() {
        let normalizer = SpellingNormalizer(locale: .uk)
        #expect(
            normalizer.normalize("My neighbor's behavior, honestly? Marvelous!")
                == "My neighbour's behaviour, honestly? Marvellous!"
        )
    }

    @Test func localeIdentifiersAreReal() {
        #expect(EnglishLocale.us.localeIdentifier == "en-US")
        #expect(EnglishLocale.uk.localeIdentifier == "en-GB")
        #expect(EnglishLocale.sg.localeIdentifier == "en-SG")
        #expect(EnglishLocale.india.localeIdentifier == "en-IN")
    }
}
