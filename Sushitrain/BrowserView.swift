import SwiftUI
import SushitrainCore
import QuickLook

struct BrowserView: View {
    var folder: SushitrainFolder;
    var prefix: String;
    @ObservedObject var appState: SushitrainAppState
    @State private var showSettings = false
    
    func subdirectories() -> [String] {
        do {
            return try folder.list(self.prefix, directories: true).asArray()
        }
        catch let error {
            print("Error listing: \(error.localizedDescription)")
        }
        return []
    }
    
    func files() -> [SushitrainEntry] {
        do {
            let list = try folder.list(self.prefix, directories: false)
            var entries: [SushitrainEntry] = [];
            for i in 0..<list.count() {
                let path = list.item(at: i)
                if let fileInfo = try? folder.getFileInformation(self.prefix + path) {
                    if fileInfo.isDirectory() || fileInfo.isSymlink() {
                        continue
                    }
                    entries.append(fileInfo)
                }
            }
            return entries
        }
        catch let error {
            print("Error listing: \(error.localizedDescription)")
        }
        return []
    }
    
    var body: some View {
        let subdirectories = self.subdirectories();
        let files = self.files();
        let isEmpty = subdirectories.isEmpty && files.isEmpty;
        
        NavigationStack {
            List {
                Section {
                    FolderStatusView(appState: appState, folder: folder)
                    
                    if try! self.folder.extraneousFiles().count() > 0 {
                        NavigationLink(destination: {
                            ExtraFilesView(folder: self.folder, appState: self.appState)
                        }) {
                            Label("This folder has new files", systemImage: "exclamationmark.triangle.fill").foregroundColor(.orange)
                        }
                    }
                }
                
                Section {
                    ForEach(subdirectories, id: \.self) {
                        key in NavigationLink(destination: BrowserView(folder: folder, prefix: "\(prefix)\(key)/", appState: appState)) {
                            Label(key, systemImage: "folder")
                        }
                        .navigationBarTitleDisplayMode(.inline)
                        .contextMenu(ContextMenu(menuItems: {
                            NavigationLink("Folder properties", destination: FileView(file: try! folder.getFileInformation(self.prefix + key), folder: self.folder, appState: self.appState))
                        }))
                    }
                }
                
                Section {
                    ForEach(files, id: \.self) {
                        file in NavigationLink(destination: FileView(file: file, folder: self.folder, appState: self.appState)) {
                            Label(file.fileName(), systemImage: file.isLocallyPresent() ? "doc.fill" : (file.isSelected() ? "doc.badge.ellipsis" : "doc"))
                        }
                    }
                }
            }
            .navigationTitle(prefix.isEmpty ? self.folder.label() : prefix)
            .overlay {
                if isEmpty && self.prefix == "" {
                    if self.folder.connectedPeerCount() == 0 {
                        ContentUnavailableView("Not connected", systemImage: "network.slash", description: Text("Share this folder with other devices to start synchronizing files.")).onTapGesture {
                            showSettings = true
                        }
                    }
                    else {
                        ContentUnavailableView("There are currently no files in this folder.", systemImage: "questionmark.folder", description: Text("If this is unexpected, ensure that the other devices have accepted syncing this folder with your device.")).onTapGesture {
                            showSettings = true
                        }
                    }
                }
            }
            .toolbar {
                ToolbarItem {
                    Button("Settings", systemImage: "folder.badge.gearshape", action: {
                        showSettings = true
                    }).labelStyle(.iconOnly)
                }
                ToolbarItem {
                    Button("Open in Files app", systemImage: "arrow.up.forward.app", action: {
                        let documentsUrl =  FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                        var error: NSError? = nil
                        var folderURL = URL(fileURLWithPath: self.folder.localNativePath(&error))
                        if error == nil {
                            folderURL.append(path: self.prefix)
                            print("folderURL", folderURL, documentsUrl)
                            
                            let sharedurl = folderURL.absoluteString.replacingOccurrences(of: "file://", with: "shareddocuments://")
                            let furl:URL = URL(string: sharedurl)!
                            UIApplication.shared.open(furl, options: [:], completionHandler: nil)
                        }
                    }).labelStyle(.iconOnly)
                }
            }
            .sheet(isPresented: $showSettings, content: {
                NavigationStack {
                    FolderView(folder: self.folder, appState: self.appState).toolbar(content: {
                        ToolbarItem(placement: .confirmationAction, content: {
                            Button("Done") {
                                showSettings = false
                            }
                        })
                    })
                }
            })
        }
    }
}
