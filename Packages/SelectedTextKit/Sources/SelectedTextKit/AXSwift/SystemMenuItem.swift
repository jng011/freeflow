//
//  SystemMenuItem.swift
//  SelectedTextKit
//
//  Created by tisfeng on 2025/9/5.
//

import Foundation

/// System menu item identifiers and related functionality
public enum SystemMenuItem: CaseIterable, RawRepresentable {
    public typealias RawValue = String

    // Built-in system menu item identifiers, also known as action selectors
    case copy
    case paste
    case cut
    case undo
    case selectAll

    // Custom menu item type
    case custom(identifier: String, shortcutChar: String? = nil, localizedTitles: Set<String> = [])

    /// All built-in system menu item types
    public static var allCases: [SystemMenuItem] {
        [.copy, .paste, .cut, .undo, .selectAll]
    }

    /// Initialize from built-in identifier
    public init?(rawValue: String) {
        switch rawValue {
        case "copy:":
            self = .copy
        case "paste:":
            self = .paste
        case "cut:":
            self = .cut
        case "undo:":
            self = .undo
        case "selectAll:":
            self = .selectAll
        default:
            return nil
        }
    }

    /// Menu item identifier (action selector)
    public var rawValue: String {
        switch self {
        case .copy: return "copy:"
        case .paste: return "paste:"
        case .cut: return "cut:"
        case .undo: return "undo:"
        case .selectAll: return "selectAll:"
        case .custom(let identifier, _, _): return identifier
        }
    }

    /// Expected keyboard shortcut character for this menu item
    public var shortcutChar: String? {
        switch self {
        case .copy: return "C"
        case .paste: return "V"
        case .cut: return "X"
        case .undo: return "Z"
        case .selectAll: return "A"
        case .custom(_, let shortcutChar, _): return shortcutChar
        }
    }

    /// Get the localized titles for this menu item type
    public var localizedTitles: Set<String> {
        switch self {
        case .copy:
            return Self.copyTitles
        case .paste:
            return Self.pasteTitles
        case .cut:
            return Self.cutTitles
        case .undo:
            return Self.undoTitles
        case .selectAll:
            return Self.selectAllTitles
        case .custom(_, _, let localizedTitles):
            return localizedTitles
        }
    }

    /// Check if the given title matches this menu item type
    public func matchesTitle(_ title: String?) -> Bool {
        guard let title else { return false }
        return localizedTitles.contains(title)
    }
}

// MARK: - Localized Titles

extension SystemMenuItem {
    /// Menu bar copy titles set, include most of the languages
    private static let copyTitles: Set<String> = [
        "Copy",  // English
        "拷贝", "复制",  // Simplified Chinese
        "拷貝", "複製",  // Traditional Chinese
        "コピー",  // Japanese
        "복사",  // Korean
        "Copier",  // French
        "Copiar",  // Spanish, Portuguese
        "Copia",  // Italian
        "Kopieren",  // German
        "Копировать",  // Russian
        "Kopiëren",  // Dutch
        "Kopiér",  // Danish
        "Kopiera",  // Swedish
        "Kopioi",  // Finnish
        "Αντιγραφή",  // Greek
        "Kopyala",  // Turkish
        "Salin",  // Indonesian
        "Sao chép",  // Vietnamese
        "คัดลอก",  // Thai
        "Копіювати",  // Ukrainian
        "Kopiuj",  // Polish
        "Másolás",  // Hungarian
        "Kopírovat",  // Czech
        "Kopírovať",  // Slovak
        "Kopiraj",  // Croatian, Serbian (Latin)
        "Копирај",  // Serbian (Cyrillic)
        "Копиране",  // Bulgarian
        "Kopēt",  // Latvian
        "Kopijuoti",  // Lithuanian
        "Copiază",  // Romanian
        "העתק",  // Hebrew
        "نسخ",  // Arabic
        "کپی",  // Persian
    ]

    /// Menu bar paste titles set, include most of the languages
    private static let pasteTitles: Set<String> = [
        "Paste",  // English
        "粘贴", "贴上",  // Simplified Chinese
        "貼上", "粘貼",  // Traditional Chinese
        "ペースト",  // Japanese
        "붙여넣기",  // Korean
        "Coller",  // French
        "Pegar",  // Spanish, Portuguese
        "Incolla",  // Italian
        "Einfügen",  // German
        "Вставить",  // Russian
        "Plakken",  // Dutch
        "Indsæt",  // Danish
        "Klistra in",  // Swedish
        "Liitä",  // Finnish
        "Επικόλληση",  // Greek
        "Yapıştır",  // Turkish
        "Tempel",  // Indonesian
        "Dán",  // Vietnamese
        "วาง",  // Thai
        "Вставити",  // Ukrainian
        "Wklej",  // Polish
        "Beillesztés",  // Hungarian
        "Vložit",  // Czech
        "Vložiť",  // Slovak
        "Umetni",  // Croatian, Serbian (Latin)
        "Умеитни",  // Serbian (Cyrillic)
        "Поставяне",  // Bulgarian
        "Ielīmēt",  // Latvian
        "Įklijuoti",  // Lithuanian
        "Lipește",  // Romanian
        "הדבק",  // Hebrew
        "لصق",  // Arabic
        "چسباندن",  // Persian
    ]

    /// Menu bar cut titles set, include most of the languages
    private static let cutTitles: Set<String> = [
        "Cut",  // English
        "剪切", "剪下",  // Simplified Chinese
        "剪下", "剪切",  // Traditional Chinese
        "カット",  // Japanese
        "잘라내기",  // Korean
        "Couper",  // French
        "Cortar",  // Spanish, Portuguese
        "Taglia",  // Italian
        "Ausschneiden",  // German
        "Вырезать",  // Russian
        "Knippen",  // Dutch
        "Klip",  // Danish
        "Klipp ut",  // Swedish
        "Leikkaa",  // Finnish
        "Αποκοπή",  // Greek
        "Kes",  // Turkish
        "Potong",  // Indonesian
        "Cắt",  // Vietnamese
        "ตัด",  // Thai
        "Вирізати",  // Ukrainian
        "Wytnij",  // Polish
        "Kivágás",  // Hungarian
        "Vyjmout",  // Czech
        "Vystrihnúť",  // Slovak
        "Izreži",  // Croatian, Serbian (Latin)
        "Исеци",  // Serbian (Cyrillic)
        "Изрязване",  // Bulgarian
        "Izgriezt",  // Latvian
        "Iškirpti",  // Lithuanian
        "Taie",  // Romanian
        "גזור",  // Hebrew
        "قص",  // Arabic
        "برش",  // Persian
    ]

    /// Menu bar undo titles set, include most of the languages
    private static let undoTitles: Set<String> = [
        "Undo",  // English
        "撤销", "还原",  // Simplified Chinese
        "撤銷", "復原",  // Traditional Chinese
        "取り消す", "元に戻す",  // Japanese
        "실행 취소",  // Korean
        "Annuler",  // French
        "Deshacer", "Desfazer",  // Spanish, Portuguese
        "Annulla",  // Italian
        "Rückgängig",  // German
        "Отменить",  // Russian
        "Ongedaan maken",  // Dutch
        "Fortryd",  // Danish
        "Ångra",  // Swedish
        "Kumoa",  // Finnish
        "Αναίρεση",  // Greek
        "Geri Al",  // Turkish
        "Urungkan",  // Indonesian
        "Hoàn tác",  // Vietnamese
        "เลิกทำ",  // Thai
        "Скасувати",  // Ukrainian
        "Cofnij",  // Polish
        "Visszavonás",  // Hungarian
        "Zpět",  // Czech
        "Späť",  // Slovak
        "Poništi",  // Croatian, Serbian (Latin)
        "Поништи",  // Serbian (Cyrillic)
        "Отмяна",  // Bulgarian
        "Atsaukt",  // Latvian
        "Anuliuoti",  // Lithuanian
        "Anulează",  // Romanian
        "בטל",  // Hebrew
        "تراجع",  // Arabic
        "واگردانی",  // Persian
    ]

    /// Menu bar select all titles set, include most of the languages
    private static let selectAllTitles: Set<String> = [
        "Select All",  // English
        "全选", "选择全部",  // Simplified Chinese
        "全選", "選擇全部",  // Traditional Chinese
        "すべて選択",  // Japanese
        "모두 선택",  // Korean
        "Tout sélectionner",  // French
        "Seleccionar todo",  // Spanish, Portuguese
        "Seleziona tutto",  // Italian
        "Alles auswählen",  // German
        "Выбрать все",  // Russian
        "Alles selecteren",  // Dutch
        "Vælg alt",  // Danish
        "Välj alla",  // Swedish
        "Valitse kaikki",  // Finnish
        "Επιλογή όλων",  // Greek
        "Tümünü seç",  // Turkish
        "Pilih semua",  // Indonesian
        "Chọn tất cả",  // Vietnamese
        "เลือกทั้งหมด",  // Thai
        "Вибрати все",  // Ukrainian
        "Zaznacz wszystko",  // Polish
        "Összes kijelölése",  // Hungarian
        "Vybrat vše",  // Czech
        "Vybrať všetko",  // Slovak
        "Odaberi sve",  // Croatian, Serbian (Latin)
        "Одабери све",  // Serbian (Cyrillic)
        "Избиране на всички",  // Bulgarian
        "Atlasīt visu",  // Latvian
        "Pažymėti viską",  // Lithuanian
        "Selectează tot",  // Romanian
        "בחר הכל",  // Hebrew
        "تحديد الكل",  // Arabic
        "انتخاب همه",  // Persian
    ]
}
