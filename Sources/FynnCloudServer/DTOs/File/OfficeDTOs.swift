import JWT
import Vapor

// MARK: - Native EuroOffice (DocsAPI) DTOs

/// The DocsAPI editor configuration handed to the browser. Also signed (minus `token`) with the
/// shared EuroOffice secret and echoed back in `token` so the document server can validate it.
struct EuroOfficeConfig: Content, JWTPayload {
    struct Permissions: Content {
        let edit: Bool
        let download: Bool
        let print: Bool
    }

    struct Document: Content {
        let fileType: String
        let key: String
        let title: String
        let url: String
        let permissions: Permissions
    }

    struct User: Content {
        let id: String
        let name: String
        /// Avatar URL shown for the user in co-editing presence/cursors. Omitted when absent.
        let image: String?
    }

    struct Customization: Content {
        /// When true, saves mid-session (status 6). Kept false so the content hash / co-editing key
        /// stays stable and the host only persists on session end (status 2).
        let forcesave: Bool
        /// Show the editor's built-in close button (handled via the DocsAPI onRequestClose event).
        let close: Close?

        struct Close: Content {
            let visible: Bool
        }
    }

    struct EditorConfig: Content {
        let mode: String
        let lang: String
        let callbackUrl: String
        let user: User
        let customization: Customization
        /// Enables real-time co-editing when multiple users share the same document `key`.
        let coEditing: CoEditing?

        struct CoEditing: Content {
            let mode: String
            let change: Bool
        }
    }

    let document: Document
    let documentType: String
    let editorConfig: EditorConfig
    /// Populated after signing; absent while the config is being signed.
    var token: String?

    func verify(using algorithm: some JWTAlgorithm) async throws {}
}

/// Raw body of the document server save callback (`POST /api/office/callback`).
struct OfficeCallbackRequest: Content {
    let key: String?
    let status: Int?
    let url: String?
    let token: String?
    let forcesavetype: Int?
}

/// Verified claims of the JWT the document server embeds in the callback body when JWT is enabled.
struct OfficeCallbackPayload: JWTPayload {
    let key: String?
    let status: Int?
    let url: String?
    let forcesavetype: Int?

    func verify(using algorithm: some JWTAlgorithm) async throws {}
}

/// Fixed response shape the document server expects from the callback endpoint.
struct OfficeCallbackResponse: Content {
    let error: Int
}

/// Unified editor bootstrap returned to the UI. `mode` selects which fields are populated.
struct EditorBootstrap: Content {
    let mode: String
    let fileName: String

    // native
    let documentServerApiUrl: String?
    let config: EuroOfficeConfig?

    // wopi
    let editorUrl: String?
    let accessToken: String?
    let accessTokenTtl: Int64?

    static func native(fileName: String, documentServerApiUrl: String, config: EuroOfficeConfig) -> EditorBootstrap {
        EditorBootstrap(
            mode: "native", fileName: fileName,
            documentServerApiUrl: documentServerApiUrl, config: config,
            editorUrl: nil, accessToken: nil, accessTokenTtl: nil)
    }

    static func wopi(fileName: String, editorUrl: String, accessToken: String, accessTokenTtl: Int64) -> EditorBootstrap {
        EditorBootstrap(
            mode: "wopi", fileName: fileName,
            documentServerApiUrl: nil, config: nil,
            editorUrl: editorUrl, accessToken: accessToken, accessTokenTtl: accessTokenTtl)
    }
}
