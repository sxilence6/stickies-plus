import AppKit

/// Stickies' menu bar, item for item, with the shortcuts from its MainMenu.nib.
/// Stickies+ additions: Edit > Checklist (⇧⌘L), Window > Show Done Pile (⇧⌘D),
/// File > Import from Stickies.
enum MainMenu {
    static func make() -> NSMenu {
        let bar = NSMenu()
        let fonts = NSFontManager.shared

        let services = NSMenu(title: "Services")
        NSApp.servicesMenu = services
        bar.addItem(menu("Stickies+", [
            item("About Stickies+", "orderFrontStandardAboutPanel:"),
            .separator(),
            item("Open at Login", "toggleOpenAtLogin:"),
            .separator(),
            submenu("Services", services),
            .separator(),
            item("Hide Stickies+", "hide:", "h"),
            item("Hide Others", "hideOtherApplications:", "h", [.command, .option]),
            item("Show All", "unhideAllApplications:"),
            .separator(),
            item("Quit Stickies+", "terminate:", "q"),
        ]))

        bar.addItem(menu("File", [
            item("New Note", "newDocument:", "n"),
            item("Close", "performClose:", "w"),
            .separator(),
            item("Import Text…", "importText:"),
            item("Export Text…", "exportText:"),
            item("Import from Stickies…", "importAppleStickies:"),
            .separator(),
            item("Print…", "printDocument:", "p"),
        ]))

        bar.addItem(menu("Edit", [
            item("Undo", "undo:", "z"),
            item("Redo", "redo:", "z", [.command, .shift]),
            .separator(),
            item("Cut", "cut:", "x"),
            item("Copy", "copy:", "c"),
            item("Paste", "paste:", "v"),
            item("Paste and Match Style", "pasteAsPlainText:", "v", [.command, .option, .shift]),
            item("Delete", "delete:"),
            item("Select All", "selectAll:", "a"),
            .separator(),
            item("Checklist", "toggleChecklist:", "l", [.command, .shift]),
            item("Add Link…", "orderFrontLinkPanel:", "k"),
            .separator(),
            menu("Find", [
                item("Find…", "performFindPanelAction:", "f", tag: 1),
                item("Find Next", "performFindPanelAction:", "g", tag: 2),
                item("Find Previous", "performFindPanelAction:", "g", [.command, .shift], tag: 3),
                item("Use Selection for Find", "performFindPanelAction:", "e", tag: 7),
                item("Jump to Selection", "centerSelectionInVisibleArea:", "j"),
            ]),
            menu("Spelling and Grammar", [
                item("Show Spelling and Grammar", "showGuessPanel:", ":"),
                item("Check Document Now", "checkSpelling:", ";"),
                .separator(),
                item("Check Spelling While Typing", "toggleContinuousSpellChecking:"),
                item("Check Grammar With Spelling", "toggleGrammarChecking:"),
                item("Correct Spelling Automatically", "toggleAutomaticSpellingCorrection:"),
            ]),
            menu("Substitutions", [
                item("Show Substitutions", "orderFrontSubstitutionsPanel:"),
                .separator(),
                item("Smart Copy/Paste", "toggleSmartInsertDelete:"),
                item("Smart Quotes", "toggleAutomaticQuoteSubstitution:"),
                item("Smart Dashes", "toggleAutomaticDashSubstitution:"),
                item("Smart Links", "toggleAutomaticLinkDetection:"),
                item("Data Detectors", "toggleAutomaticDataDetection:"),
                item("Text Replacement", "toggleAutomaticTextReplacement:"),
            ]),
            menu("Transformations", [
                item("Make Upper Case", "uppercaseWord:"),
                item("Make Lower Case", "lowercaseWord:"),
                item("Capitalize", "capitalizeWord:"),
            ]),
            menu("Speech", [
                item("Start Speaking", "startSpeaking:"),
                item("Stop Speaking", "stopSpeaking:"),
            ]),
        ]))

        bar.addItem(menu("Font", [
            item("Show Fonts", "orderFrontFontPanel:", "t", target: fonts),
            item("Bold", "addFontTrait:", "b", tag: Int(NSFontTraitMask.boldFontMask.rawValue), target: fonts),
            item("Italic", "addFontTrait:", "i", tag: Int(NSFontTraitMask.italicFontMask.rawValue), target: fonts),
            item("Underline", "underline:", "u"),
            item("Strikethrough", "toggleStrikethrough:"),
            item("Outline", "outline:"),
            .separator(),
            item("Bigger", "modifyFont:", "+", tag: Int(NSFontAction.sizeUpFontAction.rawValue), target: fonts),
            item("Smaller", "modifyFont:", "-", tag: Int(NSFontAction.sizeDownFontAction.rawValue), target: fonts),
            .separator(),
            menu("Kern", [
                item("Use Default", "useStandardKerning:"),
                item("Use None", "turnOffKerning:"),
                item("Tighten", "tightenKerning:"),
                item("Loosen", "loosenKerning:"),
            ]),
            menu("Ligature", [
                item("Use Default", "useStandardLigatures:"),
                item("Use None", "turnOffLigatures:"),
                item("Use All", "useAllLigatures:"),
            ]),
            menu("Baseline", [
                item("Use Default", "unscript:"),
                item("Superscript", "superscript:"),
                item("Subscript", "subscript:"),
                item("Raise", "raiseBaseline:"),
                item("Lower", "lowerBaseline:"),
            ]),
            .separator(),
            item("Show Colors", "orderFrontColorPanel:", "c", [.command, .shift]),
            .separator(),
            item("Copy Style", "copyFont:", "c", [.command, .option]),
            item("Paste Style", "pasteFont:", "v", [.command, .option]),
        ]))

        // Stickies' six on ⌘1–⌘6, then white and the grays (⌘7–⌘0, Charcoal without a key).
        let colorKeys = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0", ""]
        var colorItems: [NSMenuItem] = []
        for (index, color) in StickyColor.allCases.enumerated() {
            if index > 0, !color.isStickiesOriginal, StickyColor.allCases[index - 1].isStickiesOriginal {
                colorItems.append(.separator())
            }
            colorItems.append(item(color.title, "clickColorMenuItem:", index < colorKeys.count ? colorKeys[index] : "", tag: index))
        }
        bar.addItem(menu("Color", colorItems))

        let window = menu("Window", [
            item("Collapse", "performCollapse:", "m"),
            item("Collapse All", "performCollapseAll:", "m", [.command, .option]),
            item("Minimize", "performMiniaturize:"),
            item("Zoom", "performZoom:", "m", [.command, .shift]),
            .separator(),
            item("Float on Top", "toggleFloatingMenuAction:", "f", [.command, .option]),
            item("Translucent", "toggleTranslucent:", "t", [.command, .option]),
            item("Use as Default", "useAsStickiesDefault:"),
            .separator(),
            item("Show Done Pile", "flipNote:", "d", [.command, .shift]),
            item("Day Board", "showDayBoard:", "b", [.command, .shift]),
            item("Show Calendar", "toggleDayCalendar:"),
            .separator(),
            item("Undo Arrange", "undoArrange:", "z", [.command, .option]),
            item("Redo Arrange", "redoArrange:", "z", [.command, .option, .shift]),
            menu("Arrange By", [
                item("Color", "arrange:", tag: 0),
                item("Content", "arrange:", tag: 1),
                item("Date", "arrange:", tag: 2),
                item("Location on Screen", "arrange:", tag: 3),
                .separator(),
                disabled("When Arranging:"),
                item("Collapse All", "chooseCollapseWhenArranging:", tag: 1),
                item("Expand All", "chooseCollapseWhenArranging:", tag: 2),
                item("Don’t Collapse or Expand", "chooseCollapseWhenArranging:", tag: 0),
            ]),
            .separator(),
            item("Bring All to Front", "arrangeInFront:"),
        ])
        bar.addItem(window)
        NSApp.windowsMenu = window.submenu

        let help = menu("Help", [item("Stickies+ Help", "showHelp:", "?")])
        bar.addItem(help)
        NSApp.helpMenu = help.submenu
        return bar
    }

    private static func item(_ title: String, _ action: String, _ key: String = "",
                             _ modifiers: NSEvent.ModifierFlags = .command, tag: Int = 0,
                             target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: Selector(action), keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        item.tag = tag
        item.target = target
        return item
    }

    private static func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private static func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let menu = NSMenu(title: title)
        items.forEach { menu.addItem($0) }
        return submenu(title, menu)
    }

    private static func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}
