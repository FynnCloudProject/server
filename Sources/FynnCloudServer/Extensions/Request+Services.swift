import SotoS3
import Vapor

extension Request {
    var storageService: StorageService {
        let provider = application.fileStorage
        return StorageService(
            provider: provider,
            eventLoop: self.eventLoop
        )
    }

    var fileServiceContext: FileServiceContext {
        FileServiceContext(
            db: self.db,
            logger: self.logger,
            storage: self.storageService,
            redis: self.redis,
            embedding: self.embedding,
            semanticSearchThreshold: AppSettings.SemanticSearchThreshold.defaultValue,
            syncLog: self.syncLogService
        )
    }

    func embeddingServiceAsync() async -> EmbeddingService {
        let url = (try? await self.application.settings.get(AppSettings.EmbeddingUrl.self)) ?? AppSettings.EmbeddingUrl.defaultValue
        let apiKeyRaw = try? await self.application.settings.get(AppSettings.EmbeddingApiKey.self)
        let apiKey = (apiKeyRaw?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? apiKeyRaw : nil)
        let model = (try? await self.application.settings.get(AppSettings.EmbeddingModel.self)) ?? AppSettings.EmbeddingModel.defaultValue

        return EmbeddingService(
            client: self.client,
            url: url,
            apiKey: apiKey,
            model: model,
            logger: self.logger
        )
    }

    func fileServiceContextAsync() async -> FileServiceContext {
        let isEmbeddingEnabled = (try? await self.application.settings.get(AppSettings.EmbeddingEnabled.self)) ?? true
        let embedding = isEmbeddingEnabled ? await self.embeddingServiceAsync() : nil
        let threshold = (try? await self.application.settings.get(AppSettings.SemanticSearchThreshold.self)) ?? AppSettings.SemanticSearchThreshold.defaultValue

        return FileServiceContext(
            db: self.db,
            logger: self.logger,
            storage: self.storageService,
            redis: self.redis,
            embedding: embedding,
            semanticSearchThreshold: threshold,
            syncLog: self.syncLogService
        )
    }

    var fileService: FileService { fileServiceContext.files }
    var fileAccess: FileAccessService { fileServiceContext.access }
    var fileListing: FileListingService { fileServiceContext.listing }
    var fileSearch: FileSearchService { fileServiceContext.search }
    func fileSearchAsync() async -> FileSearchService {
        let ctx = await self.fileServiceContextAsync()
        return FileSearchService(ctx)
    }
    var fileUploads: MultipartUploadService { fileServiceContext.uploads }
    var quotaService: QuotaService { fileServiceContext.quota }

    var userService: UserService {
        return UserService(db: self.db, subscriptionService: self.subscription, redis: self.redis)
    }

    var ssoService: SSOService {
        let config = self.application.ssoConfig
        return SSOService(
            db: self.db,
            userService: self.userService,
            logger: self.logger,
            groupMap: config.groupMap,
            groupImportEnabled: config.groupImport,
            groupAutoMatch: config.groupAutoMatch,
            groupPrefix: config.groupPrefix,
            autoProvision: config.autoProvision)
    }

    var syncLogService: SyncLogService {
        return SyncLogService(logger: self.logger)
    }
}
