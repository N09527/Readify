import CoreFoundation
import Foundation
import OpenCCSwift

enum ChineseConverter {
    private static let lock = NSLock()
    private static let cnToTwConverter: Converter? = try? OpenCC.converter(from: "cn", to: "twp")
    private static let twToCnConverter: Converter? = try? OpenCC.converter(from: "tw", to: "cn")

    static func convert(_ text: String, mode: ChineseConvertMode) -> String {
        guard !text.isEmpty, mode != .ORIGINAL else { return text }

        lock.lock()
        defer { lock.unlock() }

        switch mode {
        case .ORIGINAL:
            return text
        case .TO_TRADITIONAL_TW:
            if let conv = cnToTwConverter {
                return conv.convert(text)
            }
            return icuTransform(text, transform: "Simplified-Traditional")
        case .TO_SIMPLIFIED:
            if let conv = twToCnConverter {
                return conv.convert(text)
            }
            return icuTransform(text, transform: "Traditional-Simplified")
        }
    }

    private static func icuTransform(_ text: String, transform: String) -> String {
        let mutable = NSMutableString(string: text)
        CFStringTransform(mutable, nil, transform as CFString, false)
        return mutable as String
    }
}
