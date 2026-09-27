import Foundation

enum AppBrand {
    static let name = "LOVEmeliya Flow"
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.1.0"
}
