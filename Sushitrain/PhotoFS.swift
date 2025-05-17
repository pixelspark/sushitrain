// Copyright (C) 2025 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
@preconcurrency import SushitrainCore

let PhotoFSType: String = "sushitrain.photos.v1"

private class PhotoFS: NSObject {
}

private class CustomFSEntry: NSObject, SushitrainCustomFileEntryProtocol {
	let children: [CustomFSEntry]
	let isDirectory: Bool
	let entryName: String

	init(_ name: String, _ children: [CustomFSEntry]? = nil) {
		if let c = children {
			self.children = c
			self.isDirectory = true
		}
		else {
			self.children = []
			self.isDirectory = false
		}
		self.entryName = name
	}

	func isDir() -> Bool {
		return self.isDirectory
	}

	func name() -> String {
		return self.entryName
	}

	func child(at index: Int) throws -> any SushitrainCustomFileEntryProtocol {
		return self.children[index]
	}

	func childCount(_ ret: UnsafeMutablePointer<Int>?) throws {
		ret?.pointee = self.children.count
	}

	func data() throws -> Data {
		return Data()
	}
}

private class StaticCustomFSEntry: CustomFSEntry {
	let contents: Data

	init(_ name: String, contents: Data) {
		self.contents = contents
		super.init(name, nil)
	}

	override func data() throws -> Data {
		if self.isDirectory {
			return Data()
		}
		return self.contents
	}
}

extension PhotoFS: SushitrainCustomFilesystemTypeProtocol {
	func root(_ uri: String?) throws -> any SushitrainCustomFileEntryProtocol {
		Log.info("PhotoFS root uri=\(uri ?? "")")
		return CustomFSEntry(
			"",
			[
				CustomFSEntry(
					".stfolder",
					[
						CustomFSEntry(".photofs-marker")
					]),
				CustomFSEntry("DirectoryA", []),
				CustomFSEntry(
					"DirectoryB",
					[
						CustomFSEntry("DirectoryBA", []),
						StaticCustomFSEntry("FileBD.txt", contents: "Hello, world!".data(using: .utf8)!),
						StaticCustomFSEntry("FileBE.txt", contents: "Hello again, world!".data(using: .utf8)!),
					]),
			])
	}
}

func RegisterPhotoFilesystem() {
	SushitrainRegisterCustomFilesystemType(PhotoFSType, PhotoFS())
}
