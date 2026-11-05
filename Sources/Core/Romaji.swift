// SPDX-License-Identifier: MIT
// Original table-driven transliterator for common Japanese romanization.
import Foundation

enum Romaji {
    private static let syllables: [String: String] = {
        var table: [String: String] = ["a":"あ", "i":"い", "u":"う", "e":"え", "o":"お",
            "shi":"し", "chi":"ち", "tsu":"つ", "fu":"ふ", "ji":"じ", "si":"し", "ti":"ち", "tu":"つ",
            "hu":"ふ", "zi":"じ", "wo":"を", "wa":"わ", "wi":"うぃ", "we":"うぇ", "wu":"う",
            "ya":"や", "yu":"ゆ", "yo":"よ", "ye":"いぇ", "nn":"ん", "n'":"ん",
            "xtsu":"っ", "ltsu":"っ", "xtu":"っ", "ltu":"っ", "xka":"ヵ", "xke":"ヶ"]
        let regular: [(String, [String])] = [
            ("k", ["か","き","く","け","こ"]), ("g", ["が","ぎ","ぐ","げ","ご"]),
            ("s", ["さ","し","す","せ","そ"]), ("z", ["ざ","じ","ず","ぜ","ぞ"]),
            ("t", ["た","ち","つ","て","と"]), ("d", ["だ","ぢ","づ","で","ど"]),
            ("n", ["な","に","ぬ","ね","の"]), ("h", ["は","ひ","ふ","へ","ほ"]),
            ("b", ["ば","び","ぶ","べ","ぼ"]), ("p", ["ぱ","ぴ","ぷ","ぺ","ぽ"]),
            ("m", ["ま","み","む","め","も"]), ("r", ["ら","り","る","れ","ろ"])]
        for (consonant, kana) in regular {
            for (vowel, value) in zip(["a","i","u","e","o"], kana) { table[consonant + vowel] = value }
        }
        let stems = ["ky":"き", "gy":"ぎ", "sy":"し", "sh":"し", "zy":"じ", "jy":"じ", "j":"じ",
                     "ty":"ち", "ch":"ち", "cy":"ち", "dy":"ぢ", "ny":"に", "hy":"ひ", "by":"び",
                     "py":"ぴ", "my":"み", "ry":"り"]
        for (stem, kana) in stems {
            for (vowel, small) in [("a","ゃ"), ("u","ゅ"), ("o","ょ")] { table[stem + vowel] = kana + small }
        }
        for prefix in ["x", "l"] {
            for (roman, small) in [("a","ぁ"),("i","ぃ"),("u","ぅ"),("e","ぇ"),("o","ぉ"),
                                    ("ya","ゃ"),("yu","ゅ"),("yo","ょ"),("wa","ゎ")] {
                table[prefix + roman] = small
            }
        }
        for (stem, base) in [("f","ふ"),("v","ゔ"),("th","て"),("dh","で"),("kw","く"),("gw","ぐ")] {
            for (vowel, small) in [("a","ぁ"),("i","ぃ"),("u","ぅ"),("e","ぇ"),("o","ぉ")] {
                table[stem + vowel] = base + small
            }
        }
        table["fu"] = "ふ"; table["vu"] = "ゔ"; table["she"] = "しぇ"; table["che"] = "ちぇ"
        table["je"] = "じぇ"; table["tsa"] = "つぁ"; table["tsi"] = "つぃ"; table["tse"] = "つぇ"; table["tso"] = "つぉ"
        return table
    }()

    static func hiragana(_ source: String) -> String {
        let converted = source.lowercased().unicodeScalars.map { scalar -> String in
            if (0x30A1...0x30F6).contains(scalar.value), let hira = UnicodeScalar(scalar.value - 0x60) { return String(hira) }
            return String(scalar)
        }.joined()
        let letters = Array(converted)
        var result = "", offset = 0
        while offset < letters.count {
            let current = letters[offset]
            let next = offset + 1 < letters.count ? letters[offset + 1] : nil
            if current == "n" {
                if next == "'" { result += "ん"; offset += 2; continue }
                if next == "n" {
                    // The second n begins the next syllable in "konnichiha".
                    let third = offset + 2 < letters.count ? letters[offset + 2] : nil
                    result += "ん"
                    offset += third.map { "aiueoy".contains($0) } == true ? 1 : 2
                    continue
                }
                if next == nil || !"aiueoy".contains(next!) { result += "ん"; offset += 1; continue }
            }
            if let next, current == next, "bcdfghjklmpqrstvwxyz".contains(current) {
                result += "っ"; offset += 1; continue
            }
            var matched = false
            for length in stride(from: min(4, letters.count - offset), through: 1, by: -1) {
                let part = String(letters[offset..<(offset + length)])
                if let kana = syllables[part] { result += kana; offset += length; matched = true; break }
            }
            if !matched { result += current == "-" ? "ー" : String(current); offset += 1 }
        }
        return result
    }
}

enum Reading {
    static func canonical(_ value: String, language: KeyboardLanguage) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        switch language {
        case .japanese: return Romaji.hiragana(trimmed)
        case .english: return trimmed.lowercased()
        case .chinese:
            // ü has its own pinyin spelling; v avoids conflating it with u.
            let letters = trimmed.lowercased().replacingOccurrences(of: "ü", with: "v")
                .replacingOccurrences(of: "u:", with: "v")
                .filter { !$0.isWhitespace && $0 != "'" && $0 != "’" }
            // After j, q, x and y the sound is written u, so that is the spelling on record.
            return letters.replacingOccurrences(of: "([jqxy])v", with: "$1u", options: .regularExpression)
        }
    }
}
