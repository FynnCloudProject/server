import Vapor
import Fluent
import Queues

struct GenerateThumbnailsCommand: Command {
    struct Signature: CommandSignature {
        @Option(name: "force", short: "f", help: "Force regeneration of thumbnails even if file already has a thumbnail.")
        var force: Bool?
    }

    var help: String {
        "Dispatches thumbnail generation jobs for files missing thumbnails (or all files if --force is passed)."
    }

    func run(using context: CommandContext, signature: Signature) throws {
        let app = context.application
        let db = app.db
        let force = signature.force ?? false
        
        let promise = app.eventLoopGroup.next().makePromise(of: Void.self)
        promise.completeWithTask {
            context.console.print("Fetching candidate files from database...")
            var query = FileMetadata.query(on: db)
                .filter(\.$isDirectory == false)
                .filter(\.$deletedAt == nil)
            
            if !force {
                query = query.filter(\.$hasThumbnail == false)
            }
            
            let files = try await query.all()
            let queueableFiles = files.filter { GenerateThumbnailJob.supports(contentType: $0.contentType) }
            
            context.console.print("Found \(queueableFiles.count) media files to process.")
            
            var dispatched = 0
            for file in queueableFiles {
                guard let fileID = file.id else { continue }
                context.console.print("Dispatching thumbnail job for '\(file.filename)' (\(fileID))...")
                try await app.queues.queue.dispatch(
                    GenerateThumbnailJob.self,
                    ThumbnailPayload(fileID: fileID)
                )
                dispatched += 1
            }
            context.console.print("✅ Queued \(dispatched) files for thumbnail generation!")
        }
        try promise.futureResult.wait()
    }
}
