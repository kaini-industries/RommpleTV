import SwiftUI

struct SetupView: View {
    var onSaved: () -> Void
    @State private var baseURL = ""
    @State private var token = ""
    @State private var saveFailed = false
    var body: some View {
        VStack(spacing: 24) {
            Text("Connect to RomM").font(.title2)
            TextField("Server URL", text: $baseURL)
            SecureField("API token (rmm_…)", text: $token)
            Button("Save") {
                if ConfigStore.save(baseURL: baseURL, token: token) { onSaved() }
                else { saveFailed = true }
            }
            if saveFailed { Text("Enter a valid URL and token.").foregroundStyle(.red) }
            Text("Tip: use the iPhone Remote app keyboard for the token.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: 900)
    }
}
