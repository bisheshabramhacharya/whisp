import AppKit

@MainActor
func installEditingMenu() {
    let menu = NSMenu()
    let appItem = NSMenuItem(title: "Whisp", action: nil, keyEquivalent: "")
    let appMenu = NSMenu(title: "Whisp")
    appMenu.addItem(NSMenuItem(title: "Quit Whisp", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    appItem.submenu = appMenu
    menu.addItem(appItem)

    let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
    let editMenu = NSMenu(title: "Edit")
    for (title, action, key) in [
        ("Undo", Selector(("undo:")), "z"),
        ("Redo", Selector(("redo:")), "Z"),
        ("Cut", #selector(NSText.cut(_:)), "x"),
        ("Copy", #selector(NSText.copy(_:)), "c"),
        ("Paste", #selector(NSText.paste(_:)), "v"),
        ("Select All", #selector(NSText.selectAll(_:)), "a"),
    ] {
        editMenu.addItem(NSMenuItem(title: title, action: action, keyEquivalent: key))
    }
    editItem.submenu = editMenu
    menu.addItem(editItem)
    NSApp.mainMenu = menu
}
