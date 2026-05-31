# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**Olimpo** is a CRM with AI built specifically for insurance promoters (*promotorías de seguros*) in Mexico that act as intermediaries between insurance agents and GNP (the insurer). It is a **commercial product, single-tenant per client**: each client gets their own Railway project, Supabase database, and domain — no shared multi-tenancy.

The full functional specification lives in `Olimpo_Especificacion_Funcional.docx`. That document is the **single source of truth** for all functional decisions. Any change to functionality must be reflected there first.

The system is entirely in **Mexican Spanish**: UI, error messages, database values, user-facing text — everything.

---

## Monorepo Structure

```
olimpo/
├── apps/
│   ├── web/          → Next.js 15 frontend (port 3000)
│   ├── api/          → FastAPI backend (port 8000)
│   ├── admin/        → Superadmin panel (admin.olimpo.mx)
│   └── rag-ingest/   → Conversational RAG ingestion interface
├── packages/
│   ├── agents/       → AI agent logic (Python modules)
│   ├── schemas/      → Shared Pydantic models
│   ├── supabase/     → Supabase client + generated types
│   └── ui/           → Shared React components
├── infra/
│   ├── railway/      → Railway service configs
│   ├── supabase/     → SQL migrations (versioned with timestamps)
│   └── n8n/          → Exported n8n workflows
└── docs/             → Functional and technical documentation
```

---

## Tech Stack

| Layer | Technology |
|---|---|
| Frontend | Next.js 15 (App Router), React Server Components, TypeScript |
| UI | Tailwind CSS, shadcn/ui, Radix UI, Recharts/Tremor, TanStack Table, React Hook Form + Zod |
| State/Data | Zustand (global state), TanStack Query (data fetching), Supabase Realtime (live updates) |
| Backend | FastAPI (Python 3.12), Pydantic v2, Uvicorn |
| Workers | Celery + Redis (async email and agent processing) |
| Database | PostgreSQL in Supabase, pgvector for RAG, Row Level Security |
| Storage | Supabase Storage (PDFs, documents) |
| Auth | Supabase Auth (email + password, optional MFA), RLS at DB level |
| Orchestration | n8n (self-hosted in Railway), LangGraph (complex stateful agents) |
| LLMs | LiteLLM router → GPT-4o (comprehension), Claude Sonnet (reasoning), Phi-3/Mistral on RunPod (OCR) |
| Embeddings | OpenAI text-embedding-3-small |
| Documents | pikepdf, pyzipper, pymupdf, Google Vision (OCR fallback) |
| Email | Gmail API with Domain-Wide Delegation |
| Observability | Langfuse (LLM traces and costs), Sentry (errors), Logfire (FastAPI logging) |
| Deployment | Railway (monorepo), Turborepo |

---

## Development Commands

> **Note:** The project is in pre-implementation phase. Commands below reflect the intended setup.

```bash
# Monorepo (from root)
turbo build          # Build all apps
turbo dev            # Run all apps in development
turbo test           # Run all tests
turbo lint           # Lint all packages

# Frontend (apps/web)
npm run dev          # Next.js dev server
npm run build        # Production build
npm run test         # Vitest
npx playwright test  # E2E tests

# Backend (apps/api)
uvicorn main:app --reload --port 8000   # Dev server
pytest                                   # All tests
pytest tests/agents/ -v                 # Agent tests only
pytest tests/agents/test_ingesta.py     # Single test file

# Database migrations (infra/supabase)
supabase db push     # Apply pending migrations
supabase migration new <name>  # Create new migration
```

---

## AI Agent Architecture

The 6 specialized agents form a pipeline that processes each incoming email:

```
Email arrives
    ↓ Agente 1 (Ingesta)       — Extract attachments, decompress ZIPs, find ZIP passwords
    ↓ Agente 2 (Comprensión)   — Extract structured data from email body with confidence scores
    ↓ Agente 3 (OCR + Clasif.) — OCR documents (Phi-3/Mistral on RunPod), classify type
    ↓ Agente 4 (Asignación)    — Identify agent (CUA cascade), assign to analyst, create/link trámite
    ↓ Agente 5 (Validación)    — Query RAG, validate documents against GNP requirements
    ↓ Agente 6 (Redacción)     — Draft professional emails to the insurance agent
```

Each agent in `packages/agents/`:
- Is an independent Python async module
- Exposes one primary async function with typed inputs/outputs
- Logs every LLM call to Langfuse
- Records its execution in `agente_ia_log`
- Keeps prompts in separate files (not inline)
- Calls LLMs exclusively through LiteLLM — **never directly to OpenAI or Anthropic**

### LLM Router (via LiteLLM)

| Task | Default Model | Alternatives |
|---|---|---|
| Email comprehension | GPT-4o | Claude Sonnet, GPT-4o-mini |
| Document classification | GPT-4o-mini | GPT-4o, Claude Haiku |
| OCR | Phi-3 on RunPod | Google Vision, Mistral |
| RAG validation | Claude Sonnet | GPT-4o |
| Email drafting | Claude Sonnet | GPT-4o |

---

## RAG Architecture

Two specialized RAGs work together in the validation agent:

- **RAG 1 — GNP Knowledge** (`rag_gnp` table): GNP manuals, product requirements, correctly filled forms, circulars. Each chunk carries rich metadata (`ramo`, `tipo_tramite`, `tipo_documento`, `vigente_desde`, `tags`). Filter by metadata before vector search.

- **RAG 2 — Policy History** (`rag_polizas` table): Built dynamically as trámites are processed. Starts empty — no historical load. Each trámite event (validation, GNP activation, approval, rejection) adds a chunk. Over time generates intelligent pattern observations per policy.

- **Rejection Learning** (`rag_aprendizajes` table): Every GNP rejection generates a learning chunk that feeds future validations.

---

## Key Database Tables

The complete schema is in the spec document (Section 6). Critical tables:

- `tramites` — core entity with lifecycle state machine
- `correos` + `correo_tramite` — emails linked to trámites (one email → multiple trámites possible)
- `adjuntos` + `documentos` — attachments and their OCR/classification results
- `agentes` + `contacto_agente` — insurance agents catalog
- `asignacion` — (agente_id + ramo) → analista_id mapping
- `cobertura_vacaciones` — vacation coverage many-to-many with dates
- `sla_definiciones` + `sla_tramite` — configurable SLAs, no hardcoded values
- `notificaciones` + `notificaciones_config` — real-time notifications via Supabase Realtime
- `audit_log` + `agente_ia_log` — full auditability

### Trámite State Machine

Los estados se gestionan en dos tablas: `cat_estado_tramite` (catálogo con metadatos) y `estado_tramite_transicion` (transiciones válidas).

#### Estados activos
| id | Etiqueta | Descripción |
|---|---|---|
| `recibido` | Recibido | llegó por correo, sin asignar |
| `en_revision` | En revisión | analista trabajando |
| `pendiente_documentos_agente` | Docs. pendientes | se pidió al agente |
| `turnado_a_gnp` | Turnado a GNP | enviado a GNP |
| `activado_gnp` | Activado por GNP | GNP pide complemento |
| `complemento_en_revision` | Complemento en revisión | procesado por analista |
| `escalado` | Escalado | gerente/director intervino |

#### Estados terminales
| id | Etiqueta | Descripción |
|---|---|---|
| `completado` | Completado | GNP aprobó |
| `rechazado_gnp` | Rechazado por GNP | GNP rechazó |
| `cancelado` | Cancelado | cancelado antes de resolución |

#### Flujo normal
```
recibido → en_revision → pendiente_documentos_agente ↔ turnado_a_gnp
                                                    ↓
                             activado_gnp ← GNP devuelve
                                  ↓
                          complemento_en_revision → turnado_a_gnp
                                                    ↓
                                         completado | rechazodo_gnp
```

Cualquier estado activo puede escalar → `escalado` → vuelve al estado correspondiente o se cancela.

---

## Non-Negotiable Rules

These are technical decisions already made — do not deviate:

1. **No Twenty CRM.** Olimpo is built from scratch.
2. **Single-tenant only.** No shared multi-tenancy across clients.
3. **RLS on every Supabase table.** Never disable RLS, even temporarily. Policies live in migrations.
4. **LiteLLM always.** Never call OpenAI or Anthropic APIs directly.
5. **No Railway → Vercel.** Vercel is incompatible with persistent Celery workers.
6. **No hardcoded SLAs or confidence thresholds.** All configurable from Superadmin.
7. **ZIP passwords are temporary.** Delete from `adjuntos.password` after processing all files.
8. **Superadmin is separate.** `admin.olimpo.mx` is a separate app, IP-whitelisted, with separate credentials.
9. **No automatic GNP portal monitoring in initial phases.** Manual monitoring by analysts.
10. **All PostgreSQL in Supabase.** No external PostgreSQL instances.
11. **All migrations are versioned files** in `infra/supabase/migrations/`. Never modify DB manually via Supabase UI.

---

## Code Conventions

**Backend (Python)**
- Python 3.12+, `async/await` everywhere that touches DB or external services
- FastAPI with domain-separated routers (`agentes_router`, `tramites_router`, etc.)
- Pydantic v2 strict mode for all models
- SQLAlchemy + asyncpg for complex queries; `supabase-py` for simple operations
- Structured logging with `structlog` + Logfire
- Retry logic with `tenacity` for external API calls

**Frontend (TypeScript)**
- Next.js 15 App Router — Server Components by default, Client Components only when interactive
- shadcn/ui + Tailwind for all UI
- React Hook Form + Zod for all forms
- TanStack Table for large lists

**Naming**
- SQL tables: `snake_case` singular (except many-to-many junction tables)
- React components: `PascalCase`
- TypeScript functions/variables: `camelCase`
- Python functions/variables: `snake_case`
- Files: `kebab-case`
- Env vars: `SCREAMING_SNAKE_CASE`

---

## Testing

- **Backend:** pytest with Supabase fixtures; mock LLMs via LiteLLM fake mode
- **Frontend:** Vitest
- **E2E:** Playwright for critical flows
- **Coverage minimums:** 70% on AI agent logic, 50% on the rest

---

## Critical Environment Variables

```bash
# Supabase
SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY

# LLMs
OPENAI_API_KEY, ANTHROPIC_API_KEY, RUNPOD_API_KEY, RUNPOD_ENDPOINT_OCR

# Google Workspace (Domain-Wide Delegation)
GOOGLE_SERVICE_ACCOUNT_JSON, GOOGLE_WORKSPACE_DOMAIN

# Observability
LANGFUSE_PUBLIC_KEY, LANGFUSE_SECRET_KEY, SENTRY_DSN

# Configurable thresholds (also editable via Superadmin)
CONFIDENCE_AGENTE=0.75
CONFIDENCE_DOCUMENTO=0.70
CONFIDENCE_VINCULACION=0.85
FUZZY_MATCH_NOMBRE=0.85
TIMEOUT_PASSWORD_HORAS=24
```

---

## Organizational Roles (for permissions and dashboard logic)

| Role | Access |
|---|---|
| `director_general` | All branches, all data. User/role config. Read-only on operations. |
| `director_ops` | All branches, all data. SLA and notification config. |
| `gerente` | Own branch only. Sees their analysts' trámites. Manages vacation coverage. |
| `analista` | Only their assigned trámites. Cannot see others' metrics. |

RLS enforces this at the database level — not just in the frontend.

---

## Implementation Roadmap (17 weeks)

| Phase | Weeks | Scope |
|---|---|---|
| 0 — Setup | 1 | Turborepo, Railway, Supabase schema, CI/CD |
| 1 — Core CRM | 2-3 | Auth, CRUD users/agents, base UI |
| 2 — Email Ingestion | 4-5 | Agents 1-2, DWD, BCC routing, email-trámite linking |
| 3 — Document Processing | 6-7 | Agent 3 (OCR), Agent 4 (assignment), vacation coverage |
| 4 — RAG + Validation | 8-10 | pgvector, RAG ingestion interface, Agents 5-6 |
| 5 — Full GNP Cycle | 11-12 | OT capture, activations, approvals, rejections, RAG learning |
| 6 — SLAs + Dashboard | 13-14 | SLA engine, per-role dashboards, real-time notifications |
| 7 — Superadmin | 15 | admin.olimpo.mx, user impersonation, agent health |
| 8 — Go-Live | 16-17 | Integration tests, RAG population, analyst training |
