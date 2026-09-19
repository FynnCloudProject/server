import Foundation

public struct EmailTemplates: Sendable {
    public static let testEmailFallback = """
    # Mail Service Test

    Congratulations! Your **{{appName}}** mail configuration is working properly.

    ### Details:
    * **Sent at**: {{timestamp}}
    * **Recipient**: `{{recipient}}`
    * **Driver**: `{{driver}}`

    [Button: Open {{appName}}]({{frontendURL}})
    """

    public static let fileSharedFallback = """
    # {{sharerName}} shared a {{itemType}} with you

    **{{sharerName}}** has shared **{{fileName}}** with you on **{{appName}}**.

    [Button: Open {{itemTypeCap}}]({{itemURL}})
    """

    public static func fallback(for id: String) -> String {
        switch id {
        case "test_email": return testEmailFallback
        case "file_shared": return fileSharedFallback
        default: return ""
        }
    }
}
