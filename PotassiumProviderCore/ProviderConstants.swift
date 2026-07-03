import Foundation

public enum ProviderConstants {
    public static let appGroupIdentifier = "group.net.weavee.potassiumProvider"
    public static let keychainService = "net.weavee.potassiumProvider.kDrive"
    public static let keychainAccount = "oauthToken"
    public static let oauthCallbackScheme = "com.infomaniak.drive"
    public static let oauthRedirectURI = URL(string: "com.infomaniak.drive://oauth2redirect")!
    public static let oauthClientID = "9473D73C-C20F-4971-9E10-D957C563FA68"
    public static let oauthScopes = ["accounts", "drive"]
    public static let defaultRootFileID = 1
    public static let apiBaseURL = URL(string: "https://api.infomaniak.com")!
    public static let driveBaseURL = URL(string: "https://api.kdrive.infomaniak.com")!
}
