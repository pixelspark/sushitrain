// Copyright (C) 2026 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import Foundation
@preconcurrency import SushitrainCore

/// Implements a way for the Go framework to move specific files to the system trash folder.
final class SystemTrash: NSObject, SushitrainTrashHandlerProtocol {
	enum TrashError: LocalizedError {
		case fileNotFound
		case failed(error: Error)

		var errorDescription: String? {
			switch self {
			case .fileNotFound: return String(localized: "The file that needed to be trashed could not be found")
			case .failed(let error):
				return String(localized: "The file could not be moved to the system trash folder: \(error.localizedDescription)")
			}
		}
	}

	func trash(_ path: String?) throws {
		Log.info("move to trash: \(String(describing: path))")
		guard let path, !path.isEmpty, (path as NSString).isAbsolutePath else {
			throw TrashError.fileNotFound
		}
		do {
			try FileManager().trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
		}
		catch {
			Log.info("Error moving to trash: \(path) error: \(error.localizedDescription)")
			throw TrashError.failed(error: error)
		}
	}
}
