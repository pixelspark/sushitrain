// Copyright (C) 2026 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import Foundation

/// Copies while a file provider and the source sandbox grant remain available.
/// FileManager deliberately rejects name collisions; imports never replace existing files.
enum FileImportCopy {
	nonisolated static func copy(_ source: URL, to destination: URL) throws {
		let scoped = source.startAccessingSecurityScopedResource()
		defer { if scoped { source.stopAccessingSecurityScopedResource() } }
		var coordinationError: NSError?
		var copyError: Error?
		NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { url in
			do { try FileManager.default.copyItem(at: url, to: destination) }
			catch { copyError = error }
		}
		if let coordinationError { throw coordinationError }
		if let copyError { throw copyError }
	}
}
