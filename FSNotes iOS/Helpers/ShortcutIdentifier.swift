//
//  ShortcutIdentifier.swift
//  FSNotes iOS
//
//  Created by Oleksandr Glushchenko on 9/15/18.
//  Copyright © 2018 Oleksandr Glushchenko. All rights reserved.
//

import Foundation

enum ShortcutIdentifier: String {
    case makeNew
    case search
    case clipboard
    case installLatest

    // MARK: - Initializers

    init?(fullType: String) {
        guard let last = fullType.components(separatedBy: ".").last else { return nil }
        self.init(rawValue: last)
    }

    // MARK: - Properties

    var type: String {
        return Bundle.main.bundleIdentifier! + ".\(self.rawValue)"
    }

    // ./deploy-ios republishes the manifest under this pinned name on every
    // release, so the link always installs the newest ad hoc build.
    var url: URL? {
        switch self {
        case .installLatest:
            return URL(string: "itms-services://?action=download-manifest&url=https://files.chiq.me/files/fsnotes-manifest.plist")
        default:
            return nil
        }
    }
}
