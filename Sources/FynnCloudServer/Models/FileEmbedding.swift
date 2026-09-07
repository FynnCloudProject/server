import Fluent
import Vapor

final class FileEmbedding: Model, Content, @unchecked Sendable {
    static let schema = "file_embeddings"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "file_id")
    var file: FileMetadata

    @Field(key: "extracted_text")
    var extractedText: String

    @Field(key: "vector_data")
    var vectorData: String // JSON string serialized [Float] array (e.g. "[0.1, -0.3, ...]")

    init() {}

    init(id: UUID? = nil, fileID: FileMetadata.IDValue, extractedText: String, vectorData: String) {
        self.id = id
        self.$file.id = fileID
        self.extractedText = extractedText
        self.vectorData = vectorData
    }
}
