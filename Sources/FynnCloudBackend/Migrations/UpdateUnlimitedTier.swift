import Fluent

struct UpdateUnlimitedTier: AsyncMigration {
    func prepare(on database: any Database) async throws {
        // Update any tier with limit_bytes = 0 to 1 PB (1,125,899,906,842,624 bytes)
        // 1024 * 1024 * 1024 * 1024 * 1024 = 1,125,899,906,842,624
        try await StorageTier.query(on: database)
            .filter(\.$limitBytes == 0)
            .set(\.$limitBytes, to: 1_125_899_906_842_624)
            .update()
    }

    func revert(on database: any Database) async throws {
        // Revert 1 PB tiers back to 0 (Unlimited)
        try await StorageTier.query(on: database)
            .filter(\.$limitBytes == 1_125_899_906_842_624)
            .set(\.$limitBytes, to: 0)
            .update()
    }
}
