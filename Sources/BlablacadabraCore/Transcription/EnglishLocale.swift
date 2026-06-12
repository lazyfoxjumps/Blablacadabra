import Foundation

/// The English variant captions are displayed in. Whisper itself has no
/// regional English switch (it understands every accent and emits one
/// "English", US-leaning in spelling), so today this drives a display-layer
/// spelling normalizer on caption text. It is stored as a real locale id so
/// a future locale-aware engine (Apple SpeechAnalyzer, a cloud boost mode)
/// can consume it directly.
public enum EnglishLocale: String, CaseIterable, Identifiable, Sendable {
    case us, uk, au, sg, ca, india, nz, ie

    public var id: String { rawValue }

    /// The BCP 47 identifier handed to locale-aware engines.
    public var localeIdentifier: String {
        switch self {
        case .us: return "en-US"
        case .uk: return "en-GB"
        case .au: return "en-AU"
        case .sg: return "en-SG"
        case .ca: return "en-CA"
        case .india: return "en-IN"
        case .nz: return "en-NZ"
        case .ie: return "en-IE"
        }
    }

    public var label: String {
        switch self {
        case .us: return "English (US)"
        case .uk: return "English (UK)"
        case .au: return "English (Australia)"
        case .sg: return "English (Singapore)"
        case .ca: return "English (Canada)"
        case .india: return "English (India)"
        case .nz: return "English (New Zealand)"
        case .ie: return "English (Ireland)"
        }
    }

    /// Pill label: country alone, the section heading carries "English".
    public var shortLabel: String {
        switch self {
        case .us: return "US"
        case .uk: return "UK"
        case .au: return "Australia"
        case .sg: return "Singapore"
        case .ca: return "Canada"
        case .india: return "India"
        case .nz: return "New Zealand"
        case .ie: return "Ireland"
        }
    }

    /// Which spelling conventions the normalizer applies.
    /// UK/AU/SG/IN/NZ/IE share British spelling wholesale. Canada keeps
    /// British -our/-re/doubled-L/defence forms but American -ize verbs.
    var appliesBritishSpelling: Bool { self != .us }
    var appliesIseVerbs: Bool { appliesBritishSpelling && self != .ca }
}

/// Word-for-word US -> regional spelling pass over caption text.
/// Deliberately a curated dictionary, not suffix rules: blind -ize -> -ise
/// rewriting mangles words like "size" and "prize". Ambiguous words whose
/// US form is also a different valid word (meter the device, program the
/// software, check the bank kind, tire the verb) are left out on purpose.
public struct SpellingNormalizer: Sendable {
    private let map: [String: String]

    public init(locale: EnglishLocale) {
        var map: [String: String] = [:]
        if locale.appliesBritishSpelling {
            map = Self.britishCommon
            if locale.appliesIseVerbs {
                map.merge(Self.britishIseVerbs) { _, new in new }
            }
        }
        self.map = map
    }

    /// No-op for English (US); everything else gets the dictionary pass.
    public var isIdentity: Bool { map.isEmpty }

    public func normalize(_ text: String) -> String {
        guard !map.isEmpty else { return text }
        var result = ""
        result.reserveCapacity(text.count)
        var word = ""
        for character in text {
            if character.isLetter {
                word.append(character)
            } else {
                result += mapped(word)
                word = ""
                result.append(character)
            }
        }
        result += mapped(word)
        return result
    }

    private func mapped(_ word: String) -> String {
        guard !word.isEmpty, let replacement = map[word.lowercased()] else { return word }
        return Self.matchCase(of: word, to: replacement)
    }

    /// Re-applies the source word's casing onto the replacement:
    /// "color" -> "colour", "Color" -> "Colour", "COLOR" -> "COLOUR".
    private static func matchCase(of source: String, to replacement: String) -> String {
        if source == source.uppercased() && source.count > 1 {
            return replacement.uppercased()
        }
        if let first = source.first, first.isUppercase {
            return replacement.prefix(1).uppercased() + replacement.dropFirst()
        }
        return replacement
    }

    /// Shared by every non-US locale, Canada included.
    private static let britishCommon: [String: String] = [
        // -or -> -our
        "color": "colour", "colors": "colours", "colored": "coloured",
        "coloring": "colouring", "colorful": "colourful",
        "favor": "favour", "favors": "favours", "favored": "favoured",
        "favorite": "favourite", "favorites": "favourites",
        "favorable": "favourable",
        "honor": "honour", "honors": "honours", "honored": "honoured",
        "honoring": "honouring", "honorable": "honourable",
        "labor": "labour", "labors": "labours", "labored": "laboured",
        "laboring": "labouring",
        "neighbor": "neighbour", "neighbors": "neighbours",
        "neighborhood": "neighbourhood", "neighborhoods": "neighbourhoods",
        "behavior": "behaviour", "behaviors": "behaviours",
        "behavioral": "behavioural",
        "flavor": "flavour", "flavors": "flavours", "flavored": "flavoured",
        "humor": "humour", "rumor": "rumour", "rumors": "rumours",
        "armor": "armour", "harbor": "harbour", "harbors": "harbours",
        "endeavor": "endeavour", "endeavors": "endeavours",
        "vapor": "vapour", "odor": "odour", "odors": "odours",
        // -er -> -re
        "center": "centre", "centers": "centres", "centered": "centred",
        "theater": "theatre", "theaters": "theatres",
        "liter": "litre", "liters": "litres",
        "fiber": "fibre", "fibers": "fibres",
        // doubled L
        "traveled": "travelled", "traveling": "travelling",
        "traveler": "traveller", "travelers": "travellers",
        "canceled": "cancelled", "canceling": "cancelling",
        "labeled": "labelled", "labeling": "labelling",
        "modeled": "modelled", "modeling": "modelling",
        "marvelous": "marvellous",
        // -se -> -ce nouns
        "defense": "defence", "defenses": "defences",
        "offense": "offence", "offenses": "offences",
        "pretense": "pretence",
        // assorted
        "gray": "grey", "grays": "greys",
        "catalog": "catalogue", "catalogs": "catalogues",
        "jewelry": "jewellery",
        "aluminum": "aluminium",
        "mustache": "moustache",
        "pajamas": "pyjamas",
        "plow": "plough",
        "skeptical": "sceptical", "skeptic": "sceptic",
    ]

    /// British -ise/-yse verbs. Canada stays with -ize, so these only apply
    /// to UK/AU/SG/IN/NZ/IE.
    private static let britishIseVerbs: [String: String] = [
        "realize": "realise", "realizes": "realises", "realized": "realised",
        "realizing": "realising", "realization": "realisation",
        "organize": "organise", "organizes": "organises",
        "organized": "organised", "organizing": "organising",
        "organization": "organisation", "organizations": "organisations",
        "recognize": "recognise", "recognizes": "recognises",
        "recognized": "recognised", "recognizing": "recognising",
        "apologize": "apologise", "apologizes": "apologises",
        "apologized": "apologised", "apologizing": "apologising",
        "criticize": "criticise", "criticizes": "criticises",
        "criticized": "criticised", "criticizing": "criticising",
        "emphasize": "emphasise", "emphasizes": "emphasises",
        "emphasized": "emphasised", "emphasizing": "emphasising",
        "summarize": "summarise", "summarizes": "summarises",
        "summarized": "summarised", "summarizing": "summarising",
        "specialize": "specialise", "specializes": "specialises",
        "specialized": "specialised", "specializing": "specialising",
        "minimize": "minimise", "minimizes": "minimises",
        "minimized": "minimised", "minimizing": "minimising",
        "maximize": "maximise", "maximizes": "maximises",
        "maximized": "maximised", "maximizing": "maximising",
        "prioritize": "prioritise", "prioritizes": "prioritises",
        "prioritized": "prioritised", "prioritizing": "prioritising",
        "finalize": "finalise", "finalizes": "finalises",
        "finalized": "finalised", "finalizing": "finalising",
        "memorize": "memorise", "memorizes": "memorises",
        "memorized": "memorised", "memorizing": "memorising",
        "analyze": "analyse", "analyzes": "analyses",
        "analyzed": "analysed", "analyzing": "analysing",
        "paralyze": "paralyse", "paralyzed": "paralysed",
    ]
}
