    import Vapor
import Fluent
import Queues

struct ReindexFilesCommand: Command {
    struct Signature: CommandSignature {}

    var help: String {
        "Regenerates vector embeddings for all files and directories stored in the database."
    }

    func run(using context: CommandContext, signature: Signature) throws {
        let app = context.application
        let db = app.db
        
        let promise = app.eventLoopGroup.next().makePromise(of: Void.self)
        promise.completeWithTask {
            context.console.print("Fetching all non-deleted files and directories from database...")
            let files = try await FileMetadata.query(on: db)
                .filter(\.$deletedAt == nil)
                .all()
            
            context.console.print("Found \(files.count) items to index.")
            
            for file in files {
                guard let fileID = file.id else { continue }
                context.console.print("Dispatching embedding job for '\(file.filename)' (\(fileID))...")
                try await app.queues.queue.dispatch(
                    ProcessFileEmbeddingJob.self,
                    FileEmbeddingPayload(fileID: fileID)
                )
            }
            context.console.print("✅ All \(files.count) items have been queued for re-indexing!")
        }
        try promise.futureResult.wait()
    }
}
