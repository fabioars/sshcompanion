import XCTest

final class SSHCompanionUITests: XCTestCase {
    @MainActor
    func testCreateWorkspaceAndServerThenOpenTab() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()

        // Workspace
        app.buttons["toolbar.add"].click()
        let nameField = app.textFields["form.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.click()
        nameField.typeText("Produção")
        app.buttons["form.save"].click()

        // Servidor dentro do workspace recém-selecionado
        app.buttons["toolbar.add"].click()
        let dialog = app.sheets.firstMatch.exists ? app.sheets.firstMatch : app.dialogs.firstMatch
        XCTAssertTrue(dialog.waitForExistence(timeout: 5))
        let serverChoice = dialog.buttons["Servidor"].firstMatch
        XCTAssertTrue(serverChoice.waitForExistence(timeout: 5))
        serverChoice.click()
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.click()
        nameField.typeText("web-01")
        app.textFields["form.host"].click()
        app.textFields["form.host"].typeText("example.com")
        app.textFields["form.username"].click()
        app.textFields["form.username"].typeText("deploy")
        app.buttons["form.save"].click()

        // Duplo clique no servidor abre uma aba
        let row = app.descendants(matching: .any)["tree.server.web-01"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.doubleClick()
        let tab = app.descendants(matching: .any)["tab.web-01"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 5), "a aba deveria abrir após o duplo clique")
    }
}
