# ☁️ FynnCloud Server

[![Swift](https://img.shields.io/badge/Swift-6.0-orange.svg)](https://swift.org)
[![Vapor](https://img.shields.io/badge/Vapor-4.0-blue.svg)](https://vapor.codes)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

A high-performance, self-hosted cloud storage solution powered by **Swift** and **Vapor**.

## ⚠️ Development Status: Early Alpha

This project is in an **early development stage**.

* **Database Schema:** Subject to change without migrations.
* **API:** Breaking changes may occur on any commit.
* **Stability:** Not recommended for production data yet.



## 🛠 Tech Stack

* **Language:** Swift 6.0+
* **Framework:** [Vapor 4](https://vapor.codes)
* **Target:** Linux (Ubuntu), macOS

---

## ⚙️ Environment Variables

The application can be configured using the following environment variables. You can set these in your shell or via a `.env` file.

| Variable | Description | Default / Fallback |
| --- | --- | --- |
| `DATABASE_URL` | Postgres connection string (e.g., `postgres://user:pass@localhost:5432/db`) | `sqlite` (db.sqlite) |
| `JWT_SECRET` | Secret key for signing JWT tokens | Random 32-byte string |
| `CORS_ALLOWED_ORIGINS` | Allowed origin for CORS headers (Release mode only) | `http://localhost:3000` |
| `STORAGE_PATH` | Local directory for file storage (if S3 is not used) | `WorkingDir/Storage/` |
| `S3_BUCKET` | AWS S3 Bucket name (Enables S3 storage driver) | Local Storage |
| `AWS_ACCESS_KEY_ID` | AWS Access Key for S3 storage | None |
| `AWS_SECRET_ACCESS_KEY` | AWS Secret Key for S3 storage | None |


## 🚀 Execution

### Production Mode

Run with full optimizations and production-level logging:

```bash
swift run FynnCloudServer serve --env production
```

### Development Mode

Run with verbose logging and debug symbols:

```bash
swift run FynnCloudServer
```

---

## 📦 Installation & Requirements

1. Ensure you have **Swift 6.0+** installed.
2. Clone the repository:

```bash
git clone https://github.com/thilojaeggi/FynnCloudServer.git
cd FynnCloudServer
```

3. Build the project:

```bash
swift build
```

4. Run the binary:

```bash
./build/debug/FynnCloudServer
```
