import Logging
import NIOCore
import NIOPosix
import Vapor

@main
enum Entrypoint {
    static func main() async throws {
        var env = try Environment.detect()
        
        // Load .env into the process now: Application.make() below also does this, but only
        // AFTER LoggingSystem.bootstrap has already run, so LOG_FORMAT/LOG_LEVEL from .env
        // would be invisible to bootstrapLogging (only real OS env vars would be seen).
        await DotEnvFile.load(
            for: env, fileio: NonBlockingFileIO(threadPool: .singleton),
            logger: Logger(label: "dot-env-loader"))

        try bootstrapLogging(env: &env)

        // Defaults to "codes.vapor.application" if not overridden here, which is meaningless
        // once multiple services' logs are aggregated together (e.g. in Grafana Loki).
        let app = try await Application.make(
            env, .singleton, logger: Logger(label: "ch.fynncloud.server"))

        do {
            try await configure(app)
            try await app.execute()
        } catch {
            app.logger.report(error: error)
            // http client is not shut down before deinit
            
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    /// Configures SwiftLog's global logging backend from `LOG_FORMAT` / `LOG_LEVEL` in `env`.
    ///
    /// Goes through Vapor's own detector so it also consumes a `--log`/`-l` CLI flag from
    /// env.commandInput — otherwise it's left as an unconsumed argument and the `serve`
    /// command later throws `.unknownInput`, regardless of which branch below is taken.
    private static func bootstrapLogging(env: inout Environment) throws {
        let logLevel = try Logger.Level.detect(from: &env)
        let isJsonFormat = Environment.get("LOG_FORMAT")?.lowercased() == "json"

        if isJsonFormat || Environment.get("LOG_LEVEL") != nil {
            LoggingSystem.bootstrap { label in
                var handler: any LogHandler =
                    isJsonFormat
                    ? JSONLogHandler(label: label)
                    : StreamLogHandler.standardOutput(label: label)
                handler.logLevel = logLevel
                return handler
            }
        } else {
            try LoggingSystem.bootstrap(from: &env)
        }
    }
}
