import Foundation
import SwiftUI

struct AboutView: View {
    @State private var showOnboarding = false
    
    var body: some View {
        Form {
            Section("About this app") {
                Text("Synctrain is © 2024, Tommy van der Vorst (tommy@t-shaped.nl)")
            }
            
            Section("Open source components") {
                Text("This application incorporates Syncthing, which is open source software under the Mozilla Public License 2.0. Syncthing is a trademark of the Syncthing Foundation. This application is not associated with nor endorsed by the Syncthing foundation nor Syncthing contributors.")
                Link("Read more at syncthing.net", destination: URL(string: "https://syncthing.net")!)
                Link("Obtain the source code", destination: URL(string: "https://github.com/syncthing/syncthing")!)
                Link("Obtain the source code modifications", destination: URL(string: "https://github.com/pixelspark/syncthing/tree/sushi")!)
            }
            
            Button("Show introduction screen") {
                showOnboarding = true
            }
        }
        .navigationTitle("About this app")
        .sheet(isPresented: $showOnboarding, content: {
            OnboardingView().interactiveDismissDisabled()
        })
    }
}
