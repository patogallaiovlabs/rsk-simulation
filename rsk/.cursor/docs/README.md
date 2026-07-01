# Simulation LLM context docs

Use `@` references so the model does not need to scan the whole repo.

## Quick start

```
@rsk/.cursor/docs/simulation-and-caches.md
```

## Files

| File | Use when |
|------|----------|
| [simulation-and-caches.md](simulation-and-caches.md) | `rsk.conf`, docker-compose, cache tuning, memory/OOM |
| [../rsk.conf](../rsk.conf) | Live simulation config (mounted into containers) |
| [../logback.xml](../logback.xml) | Logging config (mounted; override jar default) |

## RSKj code docs

Storage implementation details live in the `repos/rskj` submodule:

```
@repos/rskj/.cursor/docs/rocksdb-storage.md
```

(Create that file if missing — see `repos/rskj` RocksDB classes.)

## Layout

```
rsk-simulation/
├── docker-compose.rskj.yml    # 4 nodes; mounts rsk/rsk.conf
├── rsk/
│   ├── rsk.conf               # HOCON overrides (edit here)
│   ├── genesis/               # genesis_*.json per gas-limit scenario
│   └── .cursor/docs/          # ← you are here
└── repos/rskj/                # RSKj source
```
