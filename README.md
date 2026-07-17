# RouteIt Platform — System Overview

> High-level architecture reference for documentation agents. Per-service details (endpoints, models, configs) live in each service's own docs — this file covers how the system fits together, not what each service does internally.

## What this is

RouteIt is a modular, multi-service ML platform for logistics/transport analytics. One Flask API hosts several self-contained ML services (computer vision and tabular), fronted by a Go rate-limiting reverse proxy and consumed by a decoupled Next.js frontend. Data persists in PostgreSQL.

**Guiding principle: KISS.** Clean, obviously-correct code over clever abstraction. Services are plug-in modules; adding one never requires touching another.

## Architecture

```
Browser ──► Next.js frontend (:3000)
                 │  fetch (NEXT_PUBLIC_API_BASE)
                 ▼
            Go rate-limiter gateway (:8080)   ── token-bucket per client IP (5 rps, burst 10)
                 │  reverse proxy (BACKEND_URL)
                 ▼
            Flask backend API (:5000)          ── JSON + MJPEG only, no HTML
                 │  SQLAlchemy (DATABASE_URL)
                 ▼
            PostgreSQL 16 ("RoadNetworks" DB)
```

Four deployable units, one repo:

| Unit | Path | Stack | Role |
|---|---|---|---|
| Backend API | `backend_routeit/` | Python 3.12, Flask, SQLAlchemy, torch/ultralytics/sklearn/onnxruntime | All ML services behind one app factory |
| Gateway | `rate_limiter/` | Go 1.26, `golang.org/x/time/rate` | Per-IP token-bucket rate limiting + reverse proxy to backend |
| Frontend | `routeit/` | Next.js 16, React 19, TypeScript, Tailwind 4, Leaflet, three.js | One page per service; talks only to the API |
| Database | Docker service | Postgres 16 (alpine) | Shared relational store; schema created + seeded at backend boot |

The backend and frontend are **fully decoupled**: the backend renders no templates and serves no static assets; CORS (configurable via `CORS_ORIGIN`, default `*`) allows the frontend origin.

## Backend (`backend_routeit/`)

### Composition model

- **`app.py`** — entrypoint. Loads `.env` (local only; dockerignored), then imports the orchestrator. Note: pandas is deliberately imported **before** torch/cv2 to avoid a Windows heap-corruption crash (0xC0000374) — do not reorder.
- **`orchestrator.py`** — `create_app()` factory. Holds `SERVICE_REGISTRY` (single source of truth: name, slug, description, optional seeder). Enables CORS, lazily imports each enabled service's routes + seed module, runs `init_db()` (create_all + seeders), registers blueprints, and exposes discovery at `GET /` and `GET /api/services`.
- **`ENABLED_SERVICES`** env var (`all` or comma-separated slugs) gates which services load. Because service imports are lazy, a slim container installing only one dependency group never imports another group's ML stack.

### `core/` — shared, service-agnostic infrastructure

Never imports from `services/`. Modules: `uploads.py` (extension-validated temp-file saves), `streams.py` (stream-URL resolution, YouTube via CamGear), `frames.py` (MJPEG encoding + generic annotate-loop taking a service-supplied `process_frame` callback), `sessions.py` (generic session registry, id → state), `jobs.py` (in-memory async job runner, thread pool, 1h TTL), `geometry.py` (point parsing, cross-product side test), and `db/` (single Engine with `pool_pre_ping`, shared `DeclarativeBase`, `session_scope()` context manager — one fresh session per unit of work, thread-safe).

`DATABASE_URL` is the single DB config knob — **no default**; missing config fails loudly at import.

### `services/` — one package per service

Each service is self-contained: `routes.py` (Flask Blueprint with unique `url_prefix`), `model.py`, `config.py`, business logic, and its own `model/` weights folder. DB-backed services add `data_models.py` (ORM), `repository.py`, and `seed.py`.

Registered services and prefixes:

| Service | Slug | Prefix | Type | Seeder |
|---|---|---|---|---|
| Traffic Reader | `traffic_reader` | `/traffic-reader` | CV — YOLO + ByteTrack vehicle detection/tracking, MJPEG sessions | — |
| Route Optimizer | `route_optimizer` | `/route-optimizer` | Tabular/graph — multi-stop TSP routing with road-surface + live-weather penalties (OSRM-backed) | `seed_locations` |
| Damaged Packages | `damaged_packages` | `/damaged-packages` | CV — package photo damaged/intact classifier (ONNX) | — |
| Driver Behavior | `driver_behavior` | `/driver-behavior` | Tabular — trip-log risk scoring + action recommendation | `seed_drivers` |
| Forecasting | `forecasting` | `/forecasting` | Tabular — delivery ETA prediction (HGB) + daily volume/late-share forecasting (GLM) | `seed_deliveries` |

`services/eta_delivery/` and `services/volume_forecast/` hold model artifacts only (`eta_hgb.joblib`, `volume_glm.joblib`) — both are served through the `forecasting` service; they are not registered services.

### Dependency groups (`requirements/`)

Split so container images install only what their enabled services need: `base.txt` (flask, sqlalchemy, psycopg2, numpy), `cv.txt` (torch, ultralytics, opencv, vidgear), `tabular.txt` (pandas, sklearn, joblib), `light.txt` (onnxruntime, pillow, requests). Root `requirements.txt` = all groups. The Dockerfile takes `ARG REQS` to build slim per-group images (CPU-only torch wheels).

### `tools/` — offline data generation (not runtime)

- `build_route_pool.py` — builds a fixed pool of delivery routes (warehouse → mall stops in Bicol) from the seeded locations table via OSRM; leg geometry cached across reruns; writes `tools/data/route_pool.json`.
- `trip_generator.py` — synthetic delivery-trip generator driven by the route pool (Ornstein-Uhlenbeck speed walk + Poisson events). One generator feeds three consumers: per-second telemetry (driver-behavior scoring), `trips.csv` (ETA training), and daily aggregates (volume forecasting). Output alignment with `driver_score.wrangle()` is intentional and load-bearing.

`backend_routeit/cache/` holds hashed JSON responses from external APIs (dev cache).

### Adding a new service (the contract)

1. Create `services/<name>/` with `routes.py` exposing a Blueprint under a unique prefix; reuse `core/` for I/O, sessions, jobs, DB.
2. Add one entry to `SERVICE_REGISTRY` in `orchestrator.py` (plus a seeder name if it owns tables).
3. Frontend: add `app/<name>/page.tsx` and an entry in `lib/services.ts`.

## Gateway (`rate_limiter/`)

~66-line Go reverse proxy. Per-client-IP token bucket (5 req/s, burst 10) via a mutex-guarded `map[ip]*rate.Limiter`; over-limit requests get `429`. Proxies everything else to `BACKEND_URL` (default `http://localhost:5000`). Listens on `:8080`. Ships as a `FROM scratch` static binary. No auth, no TLS, no config beyond `BACKEND_URL` — deliberately barebones.

## Frontend (`routeit/`)

Next.js App Router; one route folder per service under `app/` mirroring the backend services. Key conventions:

- **`lib/services.ts`** — frontend service registry driving the landing-page nav cards (route + icon + copy). Intentionally separate from the backend's `/api/services` (which is discovery/health).
- **`lib/apiClient.ts`** — shared primitives: `API_BASE` (from `NEXT_PUBLIC_API_BASE`, default `http://localhost:5000` in dev; baked to `http://localhost:8080` in Docker builds so traffic goes through the gateway), `absolute()`, `errorMessage()`.
- **`lib/<service>Client.ts`** — one typed fetch client per service.
- **`components/`** — shared UI (Sidebar, FileDrop, ModeTabs, AnalyticsPanel, StatusBar) plus per-service component folders.

Notable deps: Leaflet (route maps), three.js/@react-three/fiber + shadergradient (visual backgrounds).

## Running the system

**Dev (Windows, no Docker):** `./dev.ps1` opens three windows — Flask backend (`:5000`), Go gateway (`go run .`, `:8080`), Next dev server (`:3000`). `./dev.ps1 -Stop` kills all three by port. Backend reads `backend_routeit/.env` for `DATABASE_URL`; a local Postgres must exist.

**Docker:** `docker compose up` — services `db` (healthchecked Postgres, `pgdata` volume), `backend` (waits for healthy db), `gateway` (published `:8080`), `frontend` (published `:3000`, built with `NEXT_PUBLIC_API_BASE=http://localhost:8080`). Only gateway and frontend are exposed; the backend is reachable solely through the gateway inside the compose network.

Startup order matters: DB healthy → backend (creates schema, runs seeders) → gateway → frontend.

## Cross-cutting facts worth documenting

- **State:** relational data in Postgres; CV sessions and async jobs are **in-memory** (lost on restart, single-process assumption). Uploads go to temp files.
- **DB lifecycle:** schema via `Base.metadata.create_all()` at boot — no migration tool. Seeders are idempotent per-service imports registered in `SERVICE_REGISTRY`.
- **External dependencies:** public OSRM (route geometry — throttled, cached), a live-weather API (route penalties), YouTube/CamGear (stream ingestion).
- **Config surface (backend):** `DATABASE_URL` (required), `ENABLED_SERVICES`, `CORS_ORIGIN`. Gateway: `BACKEND_URL`. Frontend: `NEXT_PUBLIC_API_BASE` (build-time).
- **Known constraints:** no auth anywhere; rate limiting is the only traffic control; MJPEG/session endpoints assume one backend process; the pandas-before-torch import order in `app.py` is a required Windows workaround.
- **Historical context:** the platform grew out of a single-service monolith (`traffic_reader_W2`); `backend_routeit/REFACTOR_SPEC.md` records the refactor rationale and target structure, and `backend_routeit/README.md` documents backend layout and the Traffic Reader reference service in detail.

## Where the detailed docs live

- `backend_routeit/README.md` — backend layout, run instructions, Traffic Reader endpoints/flow, service-addition guide.
- `backend_routeit/REFACTOR_SPEC.md` — design rationale and module-by-module requirements.
- `lib/*Client.ts` and `services/<name>/routes.py` — authoritative per-service API surface.
- `docker-compose.yaml`, per-unit `Dockerfile`s, `dev.ps1` — deployment/runtime truth.
