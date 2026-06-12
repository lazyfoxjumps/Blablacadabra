import Foundation

/// Maps the ISO 639-1 language code Whisper reports (e.g. "id", "de") to a
/// plain English display name for the status line ("Indonesian", "German").
/// Covers Whisper's full multilingual set. Unknown or empty codes return nil
/// so the caller can fall back to a generic label.
public enum SpokenLanguage {
    /// "id" -> "Indonesian". Case-insensitive; nil for unknown/empty/"en".
    public static func displayName(forCode code: String?) -> String? {
        guard let code, !code.isEmpty else { return nil }
        return names[code.lowercased()]
    }

    /// Languages to offer in the manual "spoken language" picker, common ones
    /// first (so the everyday choices are one glance away), then the rest of
    /// Whisper's set alphabetically. "Auto-detect" is handled separately by the
    /// caller (a nil selection), so it is not in this list.
    public static let pickerList: [(code: String, name: String)] = {
        let commonCodes = [
            "en", "id", "es", "zh", "ja", "ko", "de", "fr", "pt", "ru",
            "ar", "hi", "vi", "th", "ms", "it", "nl", "tr",
        ]
        let common = commonCodes.compactMap { code in names[code].map { (code, $0) } }
        let rest = names
            .filter { !commonCodes.contains($0.key) }
            .map { (code: $0.key, name: $0.value) }
            .sorted { $0.name < $1.name }
        return common + rest
    }()

    private static let names: [String: String] = [
        "en": "English",
        "zh": "Chinese", "de": "German", "es": "Spanish", "ru": "Russian",
        "ko": "Korean", "fr": "French", "ja": "Japanese", "pt": "Portuguese",
        "tr": "Turkish", "pl": "Polish", "ca": "Catalan", "nl": "Dutch",
        "ar": "Arabic", "sv": "Swedish", "it": "Italian", "id": "Indonesian",
        "hi": "Hindi", "fi": "Finnish", "vi": "Vietnamese", "he": "Hebrew",
        "uk": "Ukrainian", "el": "Greek", "ms": "Malay", "cs": "Czech",
        "ro": "Romanian", "da": "Danish", "hu": "Hungarian", "ta": "Tamil",
        "no": "Norwegian", "th": "Thai", "ur": "Urdu", "hr": "Croatian",
        "bg": "Bulgarian", "lt": "Lithuanian", "la": "Latin", "mi": "Maori",
        "ml": "Malayalam", "cy": "Welsh", "sk": "Slovak", "te": "Telugu",
        "fa": "Persian", "lv": "Latvian", "bn": "Bengali", "sr": "Serbian",
        "az": "Azerbaijani", "sl": "Slovenian", "kn": "Kannada", "et": "Estonian",
        "mk": "Macedonian", "br": "Breton", "eu": "Basque", "is": "Icelandic",
        "hy": "Armenian", "ne": "Nepali", "mn": "Mongolian", "bs": "Bosnian",
        "kk": "Kazakh", "sq": "Albanian", "sw": "Swahili", "gl": "Galician",
        "mr": "Marathi", "pa": "Punjabi", "si": "Sinhala", "km": "Khmer",
        "sn": "Shona", "yo": "Yoruba", "so": "Somali", "af": "Afrikaans",
        "oc": "Occitan", "ka": "Georgian", "be": "Belarusian", "tg": "Tajik",
        "sd": "Sindhi", "gu": "Gujarati", "am": "Amharic", "yi": "Yiddish",
        "lo": "Lao", "uz": "Uzbek", "fo": "Faroese", "ht": "Haitian Creole",
        "ps": "Pashto", "tk": "Turkmen", "nn": "Nynorsk", "mt": "Maltese",
        "sa": "Sanskrit", "lb": "Luxembourgish", "my": "Burmese", "bo": "Tibetan",
        "tl": "Tagalog", "mg": "Malagasy", "as": "Assamese", "tt": "Tatar",
        "haw": "Hawaiian", "ln": "Lingala", "ha": "Hausa", "ba": "Bashkir",
        "jw": "Javanese", "su": "Sundanese", "yue": "Cantonese",
    ]
}
