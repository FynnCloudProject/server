import Fluent
import Vapor

actor SettingsService {
    private var cache: [String: String]?
    private let database: any Database

    init(database: any Database) {
        self.database = database
    }

    private func loadIfNeeded() async throws {
        guard cache == nil else { return }
        let rows = try await AppSetting.query(on: database).all()
        cache = Dictionary(
            uniqueKeysWithValues: rows.compactMap { row in
                guard let key = row.id else { return nil }
                return (key, row.value)
            })
    }

    func get(_ key: String) async throws -> String? {
        try await loadIfNeeded()
        return cache?[key]
    }

    func getAll() async throws -> [String: String] {
        try await loadIfNeeded()
        return cache ?? [:]
    }

    func set(_ key: String, value: String) async throws {
        try await loadIfNeeded()

        if let existing = try await AppSetting.find(key, on: database) {
            existing.value = value
            try await existing.save(on: database)
        } else {
            let setting = AppSetting(key: key, value: value)
            try await setting.create(on: database)
        }

        cache?[key] = value
    }

    func delete(_ key: String) async throws {
        try await loadIfNeeded()

        if let existing = try await AppSetting.find(key, on: database) {
            try await existing.delete(on: database)
        }

        cache?[key] = nil
    }
}

extension Application {
    private struct SettingsServiceKey: StorageKey {
        typealias Value = SettingsService
    }

    var settings: SettingsService {
        get {
            guard let service = self.storage[SettingsServiceKey.self] else {
                fatalError(
                    "SettingsService not configured. Call app.settings = ... in configure.swift"
                )
            }
            return service
        }
        set {
            self.storage[SettingsServiceKey.self] = newValue
        }
    }
}
