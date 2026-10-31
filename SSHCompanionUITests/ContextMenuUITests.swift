import XCTest

final class ContextMenuUITests: XCTestCase {
    @MainActor
    func testContextMenuActsOnClickedItem() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()

        let nameField = app.textFields["form.name"]
        func create(choice: String?, name: String, host: Bool = false) {
            app.buttons["toolbar.add"].click()
            if let choice {
                let dialog = app.sheets.firstMatch.exists ? app.sheets.firstMatch : app.dialogs.firstMatch
                XCTAssertTrue(dialog.waitForExistence(timeout: 5))
                dialog.buttons[choice].firstMatch.click()
            }
            XCTAssertTrue(nameField.waitForExistence(timeout: 5))
            nameField.click()
            nameField.typeText(name)
            if host {
                app.textFields["form.host"].click()
                app.textFields["form.host"].typeText("example.com")
                app.textFields["form.username"].click()
                app.textFields["form.username"].typeText("deploy")
            }
            app.buttons["form.save"].click()
        }

        create(choice: nil, name: "WS")
        create(choice: "Diretório", name: "Dir")
        create(choice: "Servidor", name: "srv", host: true)

        let server = app.descendants(matching: .any)["tree.server.srv"].firstMatch
        XCTAssertTrue(server.waitForExistence(timeout: 5))

        // Seleciona o workspace para garantir que a ação usa o item clicado, não a seleção.
        app.descendants(matching: .any)["tree.workspace.WS"].firstMatch.click()

        server.rightClick()
        let menu = app.menuItems
        XCTAssertTrue(menu["Conectar"].waitForExistence(timeout: 3), "menu do servidor deveria ter Conectar; itens: \(app.menuItems.allElementsBoundByIndex.map(\.title))")
        menu["Apagar"].click()
        let sheet = app.sheets.firstMatch.exists ? app.sheets.firstMatch : app.dialogs.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        let texts = sheet.staticTexts.allElementsBoundByIndex.map(\.label)
        XCTAssertTrue(texts.contains { $0.contains("servidor \"srv\"") }, "diálogo errado: \(texts)")
        sheet.buttons["Excluir"].firstMatch.click()
        XCTAssertFalse(server.waitForExistence(timeout: 2), "servidor deveria ter sido apagado")
        XCTAssertTrue(app.descendants(matching: .any)["tree.directory.Dir"].firstMatch.exists)

        // Diretório
        let dir = app.descendants(matching: .any)["tree.directory.Dir"].firstMatch
        dir.rightClick()
        XCTAssertTrue(app.menuItems["Apagar"].waitForExistence(timeout: 3))
        app.menuItems["Apagar"].click()
        let sheet2 = app.sheets.firstMatch.exists ? app.sheets.firstMatch : app.dialogs.firstMatch
        XCTAssertTrue(sheet2.waitForExistence(timeout: 5))
        let texts2 = sheet2.staticTexts.allElementsBoundByIndex.map(\.label)
        XCTAssertTrue(texts2.contains { $0.contains("diretório \"Dir\"") }, "diálogo errado: \(texts2)")
        sheet2.buttons["Excluir"].firstMatch.click()
        XCTAssertFalse(dir.waitForExistence(timeout: 2))
        XCTAssertTrue(app.descendants(matching: .any)["tree.workspace.WS"].firstMatch.exists)
    }
}
