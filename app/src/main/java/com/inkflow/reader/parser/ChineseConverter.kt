package com.inkflow.reader.parser

import com.github.houbb.opencc4j.util.ZhTwConverterUtil
import com.inkflow.reader.model.ChineseConvertMode

object ChineseConverter {
    fun convert(text: String, mode: ChineseConvertMode): String {
        if (text.isEmpty() || mode == ChineseConvertMode.ORIGINAL) return text
        return when (mode) {
            ChineseConvertMode.ORIGINAL -> text
            ChineseConvertMode.TO_TRADITIONAL_TW -> ZhTwConverterUtil.toTraditional(text)
            ChineseConvertMode.TO_SIMPLIFIED -> ZhTwConverterUtil.toSimple(text)
        }
    }
}
