import AVFoundation
import SwiftUI

@main
struct VicallDialApp: App {
    var body: some Scene {
        WindowGroup {
            DialView()
                .preferredColorScheme(.dark)
                .task {
                    // Ask once at launch; dialling without this just fails.
                    // AVAudioApplication is iOS 17+, so go through
                    // AVCaptureDevice, which is available on iOS 15.
                    if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                        AVCaptureDevice.requestAccess(for: .audio) { _ in }
                    }
                }
        }
    }
}
