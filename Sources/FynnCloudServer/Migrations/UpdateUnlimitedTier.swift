import Fluent

struct UpdateUnlimitedTier: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await StorageTier.query(on: database)
            .filter(\.$limitBytes == 0)
            .set(\.$limitBytes, to: 1_125_899_906_842_624)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await StorageTier.query(on: database)
            .filter(\.$limitBytes == 1_125_899_906_842_624)
            .set(\.$limitBytes, to: 0)
            .update()
    }
}
