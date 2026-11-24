package com.inkflow.reader.engine

/**
 * Handles Traditional Chinese vertical typesetting punctuation mapping & visual alignment.
 */
object VerticalPunctuationHelper {

    private val VERTICAL_CHAR_MAP = mapOf(
        '（' to '︵', '）' to '︶',
        '(' to '︵',  ')' to '︶',
        '「' to '﹁', '」' to '﹂',
        '『' to '﹃', '』' to '﹄',
        '《' to '︽', '》' to '︾',
        '〈' to '︿', '〉' to '﹀',
        '【' to '︻', '】' to '︼',
        '〔' to '︹', '〕' to '︺',
        '｛' to '︷', '｝' to '︸',
        '［' to '﹇', '］' to '﹈',
        '—' to '︱',  '─' to '︱',
        '…' to '⋮',  '⋯' to '⋮',
        '～' to '⌇',  '~' to '⌇',
        '：' to '︰',  ':' to '︰',
        '；' to '︔'
    )

    // Punctuation that visually sits slightly toward top-right in Traditional Chinese vertical typography
    private val TOP_RIGHT_SHIFT_CHARS = setOf('，', '。', '、', ',', '.')

    // Punctuation that should not start a line/column (行頭禁則)
    val NO_START_CHARS = setOf(
        '，', '。', '、', '；', '：', '！', '？',
        '」', '』', '）', '》', '〉', '】', '〕', '｝',
        ',', '.', ';', ':', '!', '?', ')', ']', '}'
    )

    fun mapForVertical(ch: Char): Char = VERTICAL_CHAR_MAP[ch] ?: ch

    fun needsTopRightShift(ch: Char): Boolean = ch in TOP_RIGHT_SHIFT_CHARS

    fun shouldRotate90InVertical(ch: Char): Boolean {
        return ch in 'A'..'Z' || ch in 'a'..'z' || ch in '0'..'9' || ch == '-' || ch == '/'
    }
}
