import Foundation
import SwiftUI

struct FeatureView: View {
    var image: String
    var title: String
    var description: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 15) {
            Image(systemName: image).foregroundColor(.accentColor)
                .font(.system(size: 38, weight: .light))
            VStack(alignment: .leading, spacing: 5) {
                Text(self.title).bold()
                Text(self.description)
                Spacer()
            }
        }
    }
}

struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 20) {
                self.title
                
                HStack(alignment: .center) {
                    Text("Synchronize your files securely with your other devices.")
                        .bold()
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }.frame(
                    minWidth: 0,
                    maxWidth: .infinity,
                    minHeight: 0,
                    maxHeight: .infinity,
                    alignment: .topLeading
                )
                
                Text("Before we start, we need to go over a few things:").multilineTextAlignment(.leading)
                
                FeatureView(image: "bolt.horizontal.circle",
                            title: String(localized: "Synchronization is not back-up"),
                            description: String(localized: "When you synchronize files, all changes, including deleting files, also happen on your other devices. Do not use Synctrain for back-up purposes, and always keep a back-up of your data."))
                
                FeatureView(image: "hand.raised.circle",
                            title:String(localized: "Your devices, your data, your responsibility"),
                            description: String(localized: "You decide with which devices you share which files. This also means the app makers cannot help you access or recover any lost files.")
                )
                
                FeatureView(image: "gear.circle",
                            title:String(localized: "Powered by Syncthing"),
                            description: String(localized: "This app is powered by Syncthing. This app is however not associated with or endorsed by Syncthing nor its developers. Please do not expect support from the Syncthing developers. Instead, contact the maker of this app if you have questions.")
                )
                
                self.footer.padding(.bottom).padding(10)
                
                
            }.padding(.all).padding(20)
        }
    }
    
    var title: some View {
        Text(
            "Welcome to Synctrain!"
        )
        .font(.largeTitle.bold())
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: true, vertical: true)
    }
    
    var footer: some View {
        Color.blue
            .frame(
                maxWidth: .infinity,
                minHeight: 48, maxHeight: .infinity
            )
            .cornerRadius(9.0)
            .overlay(alignment: .center) {
                Text("I understand, let's get started!").bold().foregroundColor(.white)
            }.onTapGesture {
                self.dismiss()
            }
    }
}

#Preview {
    OnboardingView()
}
