# ☁️ FynnCloud Backend

[![Swift](https://img.shields.io/badge/Swift-6.0-orange.svg)](https://swift.org)
[![Vapor](https://img.shields.io/badge/Vapor-4.0-blue.svg)](https://vapor.codes)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

A high-performance, self-hosted cloud storage solution powered by **Swift** and **Vapor**.

---

## ⚠️ Development Status: Early Alpha
This project is in an **early development stage**. 
* **Database Schema:** Subject to change without migrations.
* **API:** Breaking changes may occur on any commit.
* **Stability:** Not recommended for production data yet.

---

## 🛠 Tech Stack
* **Language:** Swift 6.0+
* **Framework:** [Vapor 4](https://vapor.codes)
* **Target:** Linux (Ubuntu), macOS

---

## 🚀 Execution

### Production Mode
Run with full optimizations and production-level logging:
```bash
swift run FynnCloudBackend serve --env production

```

### Development Mode

Run with verbose logging and debug symbols:

```bash
swift run FynnCloudBackend
```

---

## 📦 Installation & Requirements

1. Ensure you have **Swift 6.0+** installed.
2. Clone the repository:
```bash
git clone https://github.com/thilojaeggi/FynnCloudBackend.git
cd FynnCloudBackend
```


3. Build the project:
```bash
swift build
```

4. Run the binary:
```bash
./build/debug/FynnCloudBackend
```