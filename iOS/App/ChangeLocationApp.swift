import SwiftUI

@main
struct ChangeLocationApp: App {
    @State private var model: PhoneLocationModel?
    @State private var setupError: String?

    var body: some Scene {
        WindowGroup {
            Group {
                if let model {
                    PhoneLocationView(model: model)
                } else if let setupError {
                    ContentUnavailableView("无法准备本机存储", systemImage: "externaldrive.badge.exclamationmark",
                                           description: Text(setupError))
                } else {
                    ProgressView("正在准备…")
                }
            }
            .task {
                guard model == nil, setupError == nil else { return }
                do {
                    let activity = SessionActivity()
                    let model = PhoneLocationModel(service: PhoneLocationService(), activity: activity,
                                                   journal: try RecoveryJournal.applicationJournal())
                    activity.onExpiration = { [weak model] in model?.markUnknown() }
                    self.model = model
                } catch { setupError = error.localizedDescription }
            }
        }
    }
}
