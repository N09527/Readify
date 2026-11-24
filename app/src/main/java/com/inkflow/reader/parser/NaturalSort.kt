package com.inkflow.reader.parser

object NaturalSort {

    private val IMAGE_EXTENSIONS = setOf("jpg", "jpeg", "png", "webp", "bmp", "gif")

    fun isSupportedImageName(path: String): Boolean {
        val clean = path.replace('\\', '/')
        if (clean.contains("__MACOSX/") || clean.endsWith("/")) return false
        val base = clean.substringAfterLast('/')
        if (base.startsWith(".") || base.isBlank()) return false
        val ext = base.substringAfterLast('.', "").lowercase()
        return ext in IMAGE_EXTENSIONS
    }

    val COMPARATOR: Comparator<String> = Comparator { a, b ->
        compareNatural(a.lowercase(), b.lowercase())
    }

    fun compareNatural(a: String, b: String): Int {
        var ia = 0
        var ib = 0
        val na = a.length
        val nb = b.length

        while (ia < na && ib < nb) {
            val ca = a[ia]
            val cb = b[ib]

            if (ca.isDigit() && cb.isDigit()) {
                var endA = ia
                while (endA < na && a[endA].isDigit()) endA++
                var endB = ib
                while (endB < nb && b[endB].isDigit()) endB++

                val segA = a.substring(ia, endA).trimStart('0')
                val segB = b.substring(ib, endB).trimStart('0')

                if (segA.length != segB.length) {
                    return segA.length.compareTo(segB.length)
                }
                val cmp = segA.compareTo(segB)
                if (cmp != 0) return cmp

                val rawLenCmp = (endA - ia).compareTo(endB - ib)
                if (rawLenCmp != 0) return rawLenCmp

                ia = endA
                ib = endB
            } else {
                if (ca != cb) return ca.compareTo(cb)
                ia++
                ib++
            }
        }
        return (na - ia).compareTo(nb - ib)
    }
}
