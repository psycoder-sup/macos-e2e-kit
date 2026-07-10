import Carbon.HIToolbox
import Foundation

/// Physical/ANSI virtual key code → baseline lowercase Latin letter mapping — the SSOT for physical keys in
/// shortcut recording.
///
/// With a Korean input method (IME) or a different layout active, `charactersIgnoringModifiers` gives the
/// translated letter (physical "K" → "ㅋ"), so storing that as-is would make a shortcut diverge from the
/// physical key actually pressed. Shortcuts bind to the physical key (the `kVK_ANSI_*` position), so the
/// stored/displayed letter must be a baseline Latin letter independent of the input source. Pinning key code
/// → Latin letter here keeps the same letter regardless of IME/layout changes.
///
/// (Values are based on Carbon `kVK_ANSI_*` positions, so an ANSI layout is assumed.)
public enum ANSIKeyMap {
    /// Physical key code → **unshifted** lowercase baseline letter. Keys not in the table (function, control,
    /// dead keys, etc.) aren't included.
    private static let baseCharacters: [UInt16: String] = [
        // Letters a–z.
        UInt16(kVK_ANSI_A): "a", UInt16(kVK_ANSI_B): "b", UInt16(kVK_ANSI_C): "c",
        UInt16(kVK_ANSI_D): "d", UInt16(kVK_ANSI_E): "e", UInt16(kVK_ANSI_F): "f",
        UInt16(kVK_ANSI_G): "g", UInt16(kVK_ANSI_H): "h", UInt16(kVK_ANSI_I): "i",
        UInt16(kVK_ANSI_J): "j", UInt16(kVK_ANSI_K): "k", UInt16(kVK_ANSI_L): "l",
        UInt16(kVK_ANSI_M): "m", UInt16(kVK_ANSI_N): "n", UInt16(kVK_ANSI_O): "o",
        UInt16(kVK_ANSI_P): "p", UInt16(kVK_ANSI_Q): "q", UInt16(kVK_ANSI_R): "r",
        UInt16(kVK_ANSI_S): "s", UInt16(kVK_ANSI_T): "t", UInt16(kVK_ANSI_U): "u",
        UInt16(kVK_ANSI_V): "v", UInt16(kVK_ANSI_W): "w", UInt16(kVK_ANSI_X): "x",
        UInt16(kVK_ANSI_Y): "y", UInt16(kVK_ANSI_Z): "z",
        // Digits 0–9.
        UInt16(kVK_ANSI_0): "0", UInt16(kVK_ANSI_1): "1", UInt16(kVK_ANSI_2): "2",
        UInt16(kVK_ANSI_3): "3", UInt16(kVK_ANSI_4): "4", UInt16(kVK_ANSI_5): "5",
        UInt16(kVK_ANSI_6): "6", UInt16(kVK_ANSI_7): "7", UInt16(kVK_ANSI_8): "8",
        UInt16(kVK_ANSI_9): "9",
        // Common symbol keys a recorder might capture (unshifted baseline letters).
        UInt16(kVK_ANSI_Minus): "-", UInt16(kVK_ANSI_Equal): "=",
        UInt16(kVK_ANSI_LeftBracket): "[", UInt16(kVK_ANSI_RightBracket): "]",
        UInt16(kVK_ANSI_Backslash): "\\", UInt16(kVK_ANSI_Semicolon): ";",
        UInt16(kVK_ANSI_Quote): "'", UInt16(kVK_ANSI_Comma): ",",
        UInt16(kVK_ANSI_Period): ".", UInt16(kVK_ANSI_Slash): "/",
        UInt16(kVK_ANSI_Grave): "`",
    ]

    /// Returns the baseline Latin lowercase letter for a physical key code (independent of IME/layout). nil
    /// if not in the table.
    public static func character(for keyCode: UInt16) -> String? {
        baseCharacters[keyCode]
    }

    /// Baseline Latin letter → physical key code (reverse of the table above). nil if not in the table. Used
    /// for debug key input (shortcut E2E like ⌘+letter).
    public static func keyCode(for character: String) -> UInt16? {
        let lower = character.lowercased()
        return baseCharacters.first { $0.value == lower }?.key
    }
}
