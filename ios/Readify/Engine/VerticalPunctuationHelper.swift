import Foundation

enum VerticalPunctuationHelper {
    private static let verticalCharMap: [Character: Character] = [
        "（": "︵", "）": "︶",
        "(": "︵",  ")": "︶",
        "「": "﹁", "」": "﹂",
        "『": "﹃", "』": "﹄",
        "《": "︽", "》": "︾",
        "〈": "︿", "〉": "﹀",
        "【": "︻", "】": "︼",
        "〔": "︹", "〕": "︺",
        "｛": "︷", "｝": "︸",
        "［": "﹇", "］": "﹈",
        "—": "︱",  "─": "︱",
        "…": "⋮",  "⋯": "⋮",
        "～": "⌇",  "~": "⌇",
        "：": "︰",  ":": "︰",
        "；": "︔"
    ]

    private static let topRightShiftChars: Set<Character> = ["，", "。", "、", ",", "."]

    static let noStartChars: Set<Character> = [
        "，", "。", "、", "；", "：", "！", "？",
        "」", "』", "）", "》", "〉", "】", "〕", "｝",
        ",", ".", ";", ":", "!", "?", ")", "]", "}"
    ]

    static func mapForVertical(_ ch: Character) -> Character {
        verticalCharMap[ch] ?? ch
    }

    static func needsTopRightShift(_ ch: Character) -> Bool {
        topRightShiftChars.contains(ch)
    }

    static func shouldRotate90InVertical(_ ch: Character) -> Bool {
        guard let scalar = ch.unicodeScalars.first, ch.unicodeScalars.count == 1 else {
            return false
        }
        let v = scalar.value
        return (v >= 65 && v <= 90) ||   // A-Z
            (v >= 97 && v <= 122) ||     // a-z
            (v >= 48 && v <= 57) ||      // 0-9
            ch == "-" || ch == "/"
    }
}
