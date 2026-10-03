// Copyright (C) 2025 Tommy van der Vorst
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this file,
// You can obtain one at https://mozilla.org/MPL/2.0/.
import SwiftUI

/// A view that generates a tree of DisclosureGroup views for a list of paths. Intermediate
/// nodes are automatically generated. This view takes care of sorting the paths.
struct PathsOutlineGroup<Content: View>: View {
	let paths: [String]
	let disableIntermediateSelection: Bool

	@ViewBuilder var content: (_ path: String, _ intermediate: Bool) -> Content

	@State private var tree: TreeNode = TreeNode(value: "", intermediate: true)

	var body: some View {
		TreeNodeView(
			tree: self.tree,
			disableIntermediateSelection: disableIntermediateSelection,
			unroll: true,
			content: self.content
		)
		.onChange(of: paths, initial: true) { _, nv in
			self.tree = TreeNode.build(from: nv)
		}
	}
}

private struct TreeNode: Hashable, Identifiable {
	typealias ObjectIdentifier = String

	let value: String
	let intermediate: Bool
	var children: [TreeNode]? = nil

	var id: ObjectIdentifier {
		return value
	}

	static func build(from paths: [String], separator: Character = "/") -> TreeNode {
		final class Node {
			let value: String
			var intermediate: Bool = true
			var children: [String: Node] = [:]

			init(_ value: String) {
				self.value = value
			}
		}

		let root = Node("")

		// Insert each path into the mutable tree
		for path in paths {
			let components =
				path
				.split(separator: separator, omittingEmptySubsequences: true)
				.map(String.init)

			guard !components.isEmpty else { continue }

			var current = root
			for (index, c) in components.enumerated() {
				if let next = current.children[c] {
					current = next
				}
				else {
					let value = components[0...index].joined(separator: String(separator))
					let next = Node(value)
					current.children[c] = next
					current = next
				}
			}
			current.intermediate = false
		}

		// Convert nodes to tree nodes (which keeps children as an array)
		func toTreeNode(_ node: Node) -> TreeNode {
			let kids = node.children.values
				.sorted { $0.value < $1.value }
				.map(toTreeNode)

			return TreeNode(
				value: node.value,
				intermediate: node.intermediate,
				children: kids.isEmpty ? nil : kids
			)
		}

		return toTreeNode(root)
	}
}

private struct TreeNodeView<Content: View>: View {
	let tree: TreeNode
	let disableIntermediateSelection: Bool

	/// Whether to place children in the parent instead of creating a disclosure group
	/// (this is used to prevent the root node from creating a top-level disclosure group)
	let unroll: Bool
	@ViewBuilder var content: (_ path: String, _ isIntermediate: Bool) -> Content

	@State var expanded = false

	var body: some View {
		if let children = tree.children {
			if unroll {
				ForEach(children) { childTree in
					TreeNodeView(
						tree: childTree,
						disableIntermediateSelection: self.disableIntermediateSelection,
						unroll: false,
						content: self.content,
						expanded: (childTree.children?.count ?? 0) == 1
					)
				}
			}
			else {
				DisclosureGroup(
					isExpanded: $expanded,
					content: {
						if expanded {
							ForEach(children) { childTree in
								TreeNodeView(
									tree: childTree,
									disableIntermediateSelection: self.disableIntermediateSelection,
									unroll: false,
									content: self.content,
									expanded: (childTree.children?.count ?? 0) == 1
								)
							}
						}
						else {
							EmptyView()
						}
					}
				) {
					self.content(tree.value, tree.intermediate)
						.selectionDisabled(self.disableIntermediateSelection && tree.intermediate)
						.disabled(self.disableIntermediateSelection && tree.intermediate)
				}
			}
		}
		else {
			self.content(tree.value, tree.intermediate)
				.selectionDisabled(self.disableIntermediateSelection && tree.intermediate)
				.disabled(self.disableIntermediateSelection && tree.intermediate)
		}
	}
}
