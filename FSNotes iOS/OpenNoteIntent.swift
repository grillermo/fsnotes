//
//  OpenNoteIntent.swift
//  FSNotes iOS
//

import AppIntents
import UIKit

struct OpenNoteIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Note"
    static var description = IntentDescription("Opens the note with the given title in FSNotes.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Note Title")
    var noteTitle: String

    static var parameterSummary: some ParameterSummary {
        Summary("Open note \(\.$noteTitle)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let title = noteTitle.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !title.isEmpty,
              let encoded = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "fsnotes://find?id=\(encoded)"),
              let sceneDelegate = UIApplication.getSceneDelegate() else {
            return .result()
        }

        sceneDelegate.handle(url: url)
        return .result()
    }
}
