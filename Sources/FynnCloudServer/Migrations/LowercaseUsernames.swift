import Fluent

struct LowercaseUsernames: AsyncMigration {
    func prepare(on database: any Database) async throws {
        // Iterate over all users and lowercase their username
        let users = try await User.query(on: database).all()
        for user in users {
            user.username = user.username.lowercased()
            try await user.save(on: database)
        }
    }

    func revert(on database: any Database) async throws {
        // Cannot revert lowercasing without original data
    }
}
