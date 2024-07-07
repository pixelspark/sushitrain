import SwiftUI

struct FoldersView: View {
    @Environment(\.editMode) private var editMode
    @ObservedObject var appState: SushitrainAppState
    @State var showingAddFolderPopup = false
    
    var body: some View {
        ZStack {
            let folders = appState.folders().sorted()
            NavigationStack {
                List {
                    Section {
                        ForEach(folders, id: \.self) { folder in
                            NavigationLink(destination: BrowserView(folder: folder, prefix: "", appState: self.appState)) {
                                Label(folder.label().isEmpty ? folder.folderID : folder.label(), systemImage: "folder.fill")
                            }.contextMenu(ContextMenu(menuItems: {
                                NavigationLink("Folder settings", destination: FolderView(folder: folder, appState: self.appState))
                            }))
                        }
                        .onDelete(perform: { indexSet in
                            let folders = appState.folders()
                            indexSet.map { idx in
                                folders[idx]
                            }.forEach { folder in try? folder.remove() }
                        })
                    }
                    
                    Section {
                        Button("Add other folder...", systemImage: "plus", action: {
                            showingAddFolderPopup = true
                        })
                    }
                }
                .navigationTitle("Folders")
                .toolbar {
                    EditButton()
                    Button("Open in Files app", systemImage: "arrow.up.forward.app", action: {
                        let documentsUrl = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                        let sharedurl = documentsUrl.absoluteString.replacingOccurrences(of: "file://", with: "shareddocuments://")
                        let furl = URL(string: sharedurl)!
                        UIApplication.shared.open(furl, options: [:], completionHandler: nil)
                    }).labelStyle(.iconOnly)
                }
            }
        }
        .sheet(isPresented: $showingAddFolderPopup, content: {
            AddFolderView(appState: appState)
        })
    }
}
