import Foundation

enum NaturalSort {
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "bmp", "gif", "heic", "heif"]

    static func isSupportedImageName(_ path: String) -> Bool {
        let clean = path.replacingOccurrences(of: "\\", with: "/")
        if clean.contains("__MACOSX/") || clean.hasSuffix("/") {
            return false
        }
        let base = clean.components(separatedBy: "/").last ?? clean
        if base.hasPrefix(".") || base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }
        guard let dotIdx = base.lastIndex(of: ".") else { return false }
        let ext = String(base[base.index(after: dotIdx)...]).lowercased()
        return imageExtensions.contains(ext)
    }

    static func lessThan(_ a: String, _ b: String) -> Bool {
        compareNatural(a.lowercased(), b.lowercased()) < 0
    }

    static func compareNatural(_ a: String, _ b: String) -> Int {
        let charsA = Array(a.unicodeScalars)
        let charsB = Array(b.unicodeScalars)
        let na = charsA.count
        let nb = charsB.count
        var ia = 0
        var ib = 0

        func isAsciiDigit(_ s: UnicodeScalar) -> Bool {
            s.value >= 48 && s.value <= 57
        }

        while ia < na && ib < nb {
            let ca = charsA[ia]
            let cb = charsB[ib]

            if isAsciiDigit(ca) && isAsciiDigit(cb) {
                var endA = ia
                while endA < na && isAsciiDigit(charsA[endA]) { endA += 1 }
                var endB = ib
                while endB < nb && isAsciiDigit(charsB[endB]) { endB += 1 }

                var nzA = ia
                while nzA < endA && charsA[nzA].value == 48 { nzA += 1 }
                var nzB = ib
                while nzB < endB && charsB[nzB].value == 48 { nzB += 1 }

                let lenA = endA - nzA
                let lenB = endB - nzB
                if lenA != lenB {
                    return lenA < lenB ? -1 : 1
                }
                for k in 0..<lenA {
                    let va = charsA[nzA + k].value
                    let vb = charsB[nzB + k].value
                    if va != vb {
                        return va < vb ? -1 : 1
                    }
                }
                let rawLenA = endA - ia
                let rawLenB = endB - ib
                if rawLenA != rawLenB {
                    return rawLenA < rawLenB ? -1 : 1
                }
                ia = endA
                ib = endB
            } else {
                if ca.value != cb.value {
                    return ca.value < cb.value ? -1 : 1
                }
                ia += 1
                ib += 1
            }
        }

        let remA = na - ia
        let remB = nb - ib
        if remA == remB { return 0 }
        return remA < remB ? -1 : 1
    }
}
