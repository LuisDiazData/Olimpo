# Olimpo — Guía de Despliegue a Producción

> Guía completa para configurar CI/CD profesional, múltiples ambientes, backups y flujo de trabajo diario.

---

## Índice

1. [Arquitectura de ambientes](#1-arquitectura-de-ambientes)
2. [Prerequisitos](#2-prerequisitos)
3. [GitHub — Repositorio y ramas](#3-github--repositorio-y-ramas)
4. [Supabase — Proyecto staging](#4-supabase--proyecto-staging)
5. [Railway — Servicios backend](#5-railway--servicios-backend)
6. [Vercel — Frontends](#6-vercel--frontends)
7. [Variables de entorno en GitHub Secrets](#7-variables-de-entorno-en-github-secrets)
8. [Primer despliegue](#8-primer-despliegue)
9. [Flujo de trabajo diario](#9-flujo-de-trabajo-diario)
10. [Backups](#10-backups)
11. [Rollback en producción](#11-rollback-en-producción)
12. [Dominios y SSL](#12-dominios-y-ssl)
13. [Monitoreo](#13-monitoreo)

---

## 1. Arquitectura de ambientes

### Dos ambientes independientes

| Ambiente  | Rama git  | Base de datos   | Railway env    | Vercel                        |
|-----------|-----------|-----------------|----------------|-------------------------------|
| Staging   | `develop` | Supabase staging| `staging`      | Preview aliasado               |
| Producción| `main`    | Supabase prod   | `production`   | Producción con dominio propio  |

### Servicios por ambiente

```
┌─────────────────────────────────────────────────────────────────┐
│  PRODUCCIÓN (main)                                               │
│                                                                  │
│  Vercel                    Railway                               │
│  ├─ app.olimpo.mx          ├─ olimpo-api     (FastAPI, 2 workers)│
│  └─ admin.olimpo.mx        ├─ olimpo-admin   (FastAPI Superadmin)│
│                            └─ redis          (Celery, futuro)    │
│                                                                  │
│  Supabase (proyecto prod)  RunPod                                │
│  ├─ PostgreSQL             └─ OCR endpoint   (Phi-3/Mistral)     │
│  ├─ Auth                                                         │
│  ├─ Storage                                                      │
│  └─ Realtime                                                     │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│  STAGING (develop)                                               │
│                                                                  │
│  Vercel Preview             Railway                              │
│  ├─ staging.olimpo.mx       ├─ olimpo-api     (1 worker)        │
│  └─ staging-admin.olimpo.mx └─ olimpo-admin                     │
│                                                                  │
│  Supabase (proyecto staging separado)                            │
└─────────────────────────────────────────────────────────────────┘
```

### Flujo de cambios

```
feature/xxx  →  develop  →  [CI + deploy staging]  →  [probar]  →  main  →  [aprobación]  →  producción
```

---

## 2. Prerequisitos

### Cuentas necesarias

- [ ] **GitHub** — cuenta personal o de organización
- [ ] **Supabase** — plan Pro recomendado (backups automáticos, branching)
- [ ] **Railway** — plan Hobby ($5/mes) o Team
- [ ] **Vercel** — plan Pro para dominios personalizados + protección de staging
- [ ] **RunPod** — para OCR (ya tienes credenciales)
- [ ] **Sentry** — para errores (plan gratuito suficiente al inicio)
- [ ] **Logfire** — para trazas FastAPI (plan gratuito disponible)

### Herramientas locales

```bash
# Instalar Supabase CLI
brew install supabase/tap/supabase

# Instalar Railway CLI
npm install -g @railway/cli

# Instalar Vercel CLI
npm install -g vercel

# Verificar versiones
supabase --version    # >= 1.200
railway --version     # >= 3.0
vercel --version      # >= 37.0
```

---

## 3. GitHub — Repositorio y ramas

### 3.1 Crear el repositorio

```bash
# En la raíz del proyecto
git remote add origin https://github.com/LuisDiazData/Olimpo.git

# Crear rama develop desde master/main
git checkout -b develop
git push -u origin develop
git push -u origin main
```

### 3.2 Protección de ramas

Ve a **GitHub → Repositorio → Settings → Branches**.

#### Rama `main` (producción)

Crea una regla para `main` con estas opciones:
- [x] Require a pull request before merging
  - [x] Require approvals: **1**
  - [x] Dismiss stale pull request approvals when new commits are pushed
- [x] Require status checks to pass before merging
  - Busca y agrega: `CI — Todo OK`
- [x] Require branches to be up to date before merging
- [x] Do not allow bypassing the above settings

#### Rama `develop` (staging)

Crea una regla para `develop` con:
- [x] Require a pull request before merging
- [x] Require status checks to pass: `CI — Todo OK`

### 3.3 Crear GitHub Environments

Ve a **Settings → Environments**.

#### Environment `staging`
- No requiere revisores
- Variables de entorno: ninguna extra (se usan los Secrets del repo)

#### Environment `production`
- [x] **Required reviewers**: agrega tu usuario (o el del tech lead)
- [x] **Wait timer**: 0 minutos (el review es suficiente gate)
- Esto hace que cada deploy a producción pause y espere tu aprobación manual

### 3.4 Variables de los Environments

En cada environment, puedes agregar variables específicas del ambiente. Para este proyecto, todos los secrets están a nivel de repositorio (no de environment) porque los workflows los referencian con el prefijo `_STAGING` o `_PROD`.

---

## 4. Supabase — Proyecto staging

El proyecto de **producción** ya existe (`bqthpnflyqnrwjdxbnpk` — Olimpo_CRM). Necesitas crear uno separado para staging.

### 4.1 Crear proyecto staging

1. Ve a [supabase.com/dashboard](https://supabase.com/dashboard)
2. Clic en **New Project**
3. Nombre: `olimpo-staging`
4. Misma organización que el proyecto de producción
5. Región: `South America (São Paulo)` — la más cercana a México
6. Guarda la **Database Password** en un lugar seguro

### 4.2 Obtener credenciales del proyecto staging

En el dashboard del proyecto staging, ve a **Project Settings → API**:
- `Project URL` → `SUPABASE_URL` staging
- `anon public` key → `SUPABASE_ANON_KEY` staging
- `service_role` key → `SUPABASE_SERVICE_ROLE_KEY` staging
- `JWT Secret` → `SUPABASE_JWT_SECRET` staging
- **Project Reference** → necesario para los workflows (formato: `abcdefghij...`)

### 4.3 Aplicar las migraciones al proyecto staging

```bash
# Desde la raíz del proyecto
# Enlazar temporalmente al proyecto staging
supabase link --project-ref <TU_REF_STAGING>

# Crear el symlink de migraciones (necesario por la estructura del monorepo)
ln -sf $(pwd)/infra/supabase/migrations supabase/migrations

# Aplicar todas las migraciones
supabase db push

# Volver a enlazar al proyecto de producción
supabase link --project-ref bqthpnflyqnrwjdxbnpk
```

### 4.4 Habilitar extensiones necesarias en staging

En el SQL Editor del proyecto staging, ejecuta:
```sql
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "vector";
```

---

## 5. Railway — Servicios backend

### 5.1 Crear el proyecto en Railway

1. Ve a [railway.app](https://railway.app) → **New Project**
2. Nombre: `olimpo`
3. El proyecto tendrá dos **Environments**: `production` y `staging`

### 5.2 Crear los Environments

En el proyecto Railway:
1. Click en el menú del environment actual → **New Environment**
2. Crea `staging` (basado en `production`)

### 5.3 Crear los servicios

Para cada servicio, ve a **+ New → Empty Service**, y configura:

#### Servicio `olimpo-api`

En la pestaña **Settings**:
- **Source**: GitHub → tu repositorio → rama `main`
- **Root Directory**: `apps/api`
- **Watch Paths**: `apps/api/**`

Variables de entorno (en la pestaña **Variables**):
```
ENVIRONMENT=production
SUPABASE_URL=https://<ref-prod>.supabase.co
SUPABASE_ANON_KEY=eyJ...
SUPABASE_SERVICE_ROLE_KEY=eyJ...
SUPABASE_JWT_SECRET=...
OPENAI_API_KEY=sk-...
ANTHROPIC_API_KEY=sk-ant-...
RUNPOD_API_KEY=...
RUNPOD_ENDPOINT_OCR=...
GOOGLE_SERVICE_ACCOUNT_JSON={"type":"service_account",...}
GOOGLE_WORKSPACE_DOMAIN=...
GMAIL_WEBHOOK_TOKEN=...
GMAIL_PUBSUB_TOPIC=...
LOGFIRE_TOKEN=...
SENTRY_DSN=...
CORS_ORIGINS=https://app.olimpo.mx,https://admin.olimpo.mx
```

Para el environment `staging`, las mismas variables pero con los valores de staging:
```
ENVIRONMENT=staging
SUPABASE_URL=https://<ref-staging>.supabase.co
CORS_ORIGINS=https://staging.olimpo.mx,https://staging-admin.olimpo.mx
# ... resto igual pero apuntando a staging
```

#### Servicio `olimpo-admin`

En la pestaña **Settings**:
- **Source**: GitHub → tu repositorio → rama `main`
- **Root Directory**: `apps/admin`
- **Watch Paths**: `apps/admin/**`

Variables mínimas:
```
ENVIRONMENT=production
SUPABASE_URL=...
SUPABASE_SERVICE_ROLE_KEY=...
ADMIN_IP_ALLOWLIST=IP1,IP2,IP3   # IPs desde donde accede el superadmin
ADMIN_API_KEY=<uuid-seguro>
```

#### Servicio `redis` (para cuando implementes Celery)

1. **+ New → Database → Redis**
2. Railway crea Redis automáticamente
3. La variable `REDIS_URL` se inyecta automáticamente en los demás servicios si los conectas en el mismo environment

### 5.4 Obtener el Railway Token

1. Ve a **Account Settings → Tokens**
2. Crea un token nuevo: `olimpo-github-actions`
3. Guárdalo (lo necesitas en el paso 7)

### 5.5 Dominios en Railway

Para `olimpo-api`:
1. Ve al servicio → **Settings → Networking → Custom Domain**
2. Agrega `api.olimpo.mx`
3. Railway genera un certificado SSL automáticamente

Para `olimpo-admin`:
1. Agrega `api-admin.olimpo.mx` (el admin-web hace proxy a este endpoint)

---

## 6. Vercel — Frontends

### 6.1 Configurar proyecto `olimpo-web`

```bash
cd apps/web
vercel

# Responde:
# - Set up and deploy? → Y
# - Which scope? → tu cuenta/org
# - Link to existing project? → N
# - Project name? → olimpo-web
# - Directory? → ./
# - Override settings? → N
```

En el dashboard de Vercel → proyecto `olimpo-web`:

**Settings → Git**:
- Production Branch: `main`
- Preview Branches: `develop` (y todos los demás)

**Settings → Environment Variables**:

Para `Production`:
```
NEXT_PUBLIC_SUPABASE_URL=https://<ref-prod>.supabase.co
NEXT_PUBLIC_SUPABASE_ANON_KEY=eyJ...
NEXT_PUBLIC_API_URL=https://api.olimpo.mx
```

Para `Preview` (staging):
```
NEXT_PUBLIC_SUPABASE_URL=https://<ref-staging>.supabase.co
NEXT_PUBLIC_SUPABASE_ANON_KEY=eyJ...
NEXT_PUBLIC_API_URL=https://staging-api.olimpo.mx
```

**Settings → Domains**:
- Agrega `app.olimpo.mx` como dominio de producción

### 6.2 Configurar proyecto `olimpo-admin-web`

```bash
cd apps/admin-web
vercel

# Project name: olimpo-admin-web
```

Variables de entorno del admin-web:
```
# Production
NEXT_PUBLIC_ADMIN_API_URL=https://api-admin.olimpo.mx
ADMIN_SESSION_SECRET=<string-aleatorio-32-chars>

# Preview (staging)
NEXT_PUBLIC_ADMIN_API_URL=https://staging-api-admin.olimpo.mx
```

**Settings → Domains**:
- Agrega `admin.olimpo.mx`

### 6.3 Obtener IDs de proyectos Vercel

```bash
# En apps/web/ (después del vercel setup)
cat .vercel/project.json
# { "orgId": "team_xxx", "projectId": "prj_xxx" }

# En apps/admin-web/
cat .vercel/project.json
```

Guarda los valores de `orgId` y `projectId` para el paso 7.

### 6.4 Obtener el Vercel Token

1. Ve a [vercel.com/account/tokens](https://vercel.com/account/tokens)
2. Crea token: `olimpo-github-actions`
3. Alcance: Full Account (o solo el team de Olimpo)
4. Guárdalo para el paso 7

---

## 7. Variables de entorno en GitHub Secrets

Ve a **GitHub → Repositorio → Settings → Secrets and variables → Actions**.

Crea los siguientes secrets:

### Supabase

| Secret | Valor |
|--------|-------|
| `SUPABASE_ACCESS_TOKEN` | Token personal de Supabase CLI ([supabase.com/dashboard/account/tokens](https://supabase.com/dashboard/account/tokens)) |
| `SUPABASE_PROJECT_ID_PROD` | Reference del proyecto producción: `bqthpnflyqnrwjdxbnpk` |
| `SUPABASE_PROJECT_ID_STAGING` | Reference del proyecto staging |
| `SUPABASE_DB_PASSWORD_PROD` | Password de la DB de producción |
| `SUPABASE_DB_PASSWORD_STAGING` | Password de la DB de staging |

### Railway

| Secret | Valor |
|--------|-------|
| `RAILWAY_TOKEN` | Token de Railway (del paso 5.4) |

### Vercel

| Secret | Valor |
|--------|-------|
| `VERCEL_TOKEN` | Token de Vercel (del paso 6.4) |
| `VERCEL_ORG_ID` | `orgId` del archivo `.vercel/project.json` |
| `VERCEL_WEB_PROJECT_ID` | `projectId` de `apps/web/.vercel/project.json` |
| `VERCEL_ADMIN_PROJECT_ID` | `projectId` de `apps/admin-web/.vercel/project.json` |

---

## 8. Primer despliegue

### 8.1 Verificar que los workflows existen

```bash
ls .github/workflows/
# ci.yml
# deploy-staging.yml
# deploy-prod.yml
```

### 8.2 Hacer push a develop (despliega staging)

```bash
git checkout develop
git add .
git commit -m "chore: configurar CI/CD y dockerfiles"
git push origin develop
```

Ve a **GitHub → Actions** y observa el workflow `Deploy — Staging`. Tardará ~5 minutos.

Si algo falla, el error aparece en el step correspondiente. Los problemas más comunes:
- Migraciones: error en SQL → revisa el log del step "Aplicar migraciones pendientes"
- Railway: servicio no encontrado → verifica que el nombre del servicio coincide (`olimpo-api`)
- Vercel: project ID incorrecto → revisa los `.vercel/project.json`

### 8.3 Verificar staging

1. Abre `https://staging.olimpo.mx` → deberías ver el login
2. Abre `https://staging-api.olimpo.mx/health` → `{"status": "ok"}`
3. Prueba el flujo completo: login, crear usuario, crear trámite

### 8.4 Merge a main (despliega producción)

```bash
# Crear PR de develop → main en GitHub
# El CI debe pasar (status check required)
# Mergea el PR

# Después del merge, el workflow deploy-prod.yml se dispara
# PAUSA en el step "Supabase — Migraciones producción" esperando aprobación
```

Ve a **GitHub → Actions → Deploy — Producción** → click en el job pausado → **Review deployments** → aprueba.

El deploy continúa automáticamente.

---

## 9. Flujo de trabajo diario

### Para una nueva funcionalidad

```bash
# 1. Crear rama desde develop (NUNCA desde main)
git checkout develop
git pull origin develop
git checkout -b feature/nombre-de-la-funcionalidad

# 2. Desarrollar y commitear
git add .
git commit -m "feat: descripción del cambio"
git push origin feature/nombre-de-la-funcionalidad

# 3. Crear PR en GitHub: feature/xxx → develop
#    El CI corre automáticamente
#    Si CI pasa → hacer self-review → mergear

# 4. El merge a develop dispara deploy-staging automáticamente
#    Probar en staging.olimpo.mx

# 5. Cuando todo está bien → crear PR: develop → main
#    Requiere 1 aprobación + CI
#    El merge a main dispara deploy-prod con gate de aprobación
```

### Para un hotfix urgente en producción

```bash
# 1. Crear rama desde main
git checkout main
git pull origin main
git checkout -b hotfix/descripcion-del-bug

# 2. Corregir y commitear
git commit -m "fix: descripción del fix"

# 3. PR a main (aprobación rápida, CI debe pasar)
# 4. TAMBIÉN crear PR a develop para que el fix esté en staging

# En casos EXTREMADAMENTE urgentes, el dueño del repositorio puede
# hacer push directo a main (bypassing protection) si es necesario.
```

### Para una nueva migración de base de datos

```bash
# Crear el archivo de migración
# Formato: infra/supabase/migrations/YYYYMMDDHHMMSS_descripcion.sql

# Verificar localmente (requiere Supabase CLI y proyecto local corriendo)
supabase db diff

# Agregar al commit y seguir el flujo normal de feature → develop → main
# Las migraciones se aplican automáticamente en el pipeline de staging y producción
```

---

## 10. Backups

### Automáticos (Supabase Pro)

Con el plan Pro de Supabase, obtienes:
- **Backups diarios automáticos**: 7 días de retención
- **Point-in-Time Recovery (PITR)**: restaurar a cualquier segundo en los últimos 7 días

Verificar backups: **Supabase Dashboard → Project → Database → Backups**

### Backup manual antes de cambios grandes

Siempre haz un backup manual antes de una migración grande o deploy importante:

```bash
# Usando la CLI de Supabase
supabase db dump --project-ref bqthpnflyqnrwjdxbnpk > backups/prod_$(date +%Y%m%d_%H%M%S).sql

# O usando pg_dump directamente (obtén el DB URL del Supabase dashboard)
pg_dump "postgresql://postgres:<password>@db.<ref>.supabase.co:5432/postgres" \
  --format=custom \
  --file=backups/prod_$(date +%Y%m%d_%H%M%S).dump
```

Guarda estos archivos fuera del repositorio (en un bucket de Supabase Storage o Google Drive).

### Backup programado adicional (opcional)

Para tener backups en un bucket externo, puedes agregar este workflow:

```yaml
# .github/workflows/backup.yml
name: Backup semanal

on:
  schedule:
    - cron: '0 6 * * 1'  # Lunes a las 6am UTC (1am Ciudad de México)
  workflow_dispatch:

jobs:
  backup:
    runs-on: ubuntu-latest
    steps:
      - name: Instalar pg_dump
        run: sudo apt-get install -y postgresql-client

      - name: Crear backup
        run: |
          pg_dump "${{ secrets.SUPABASE_DB_URL_PROD }}" \
            --format=custom \
            --file=backup_$(date +%Y%m%d).dump

      - name: Subir a Supabase Storage
        run: |
          curl -X POST \
            -H "Authorization: Bearer ${{ secrets.SUPABASE_SERVICE_ROLE_KEY_PROD }}" \
            -F "file=@backup_$(date +%Y%m%d).dump" \
            "${{ secrets.SUPABASE_URL_PROD }}/storage/v1/object/backups/$(date +%Y%m%d).dump"
```

---

## 11. Rollback en producción

### Rollback del frontend (Vercel) — instantáneo

1. Ve a **Vercel Dashboard → proyecto → Deployments**
2. Encuentra el deployment anterior (el que funcionaba)
3. Click en los 3 puntos → **Promote to Production**

Esto es instantáneo y no afecta la base de datos.

### Rollback del backend (Railway) — muy rápido

1. Ve a **Railway Dashboard → servicio → Deployments**
2. Encuentra el deployment anterior
3. Click en el deployment → **Redeploy**

También instantáneo, Railway mantiene las imágenes Docker anteriores.

### Rollback de migraciones de base de datos — el más delicado

Las migraciones de Supabase **no tienen rollback automático**. Estrategias:

**Opción A — Restaurar backup (recomendada para errores graves):**
1. Ir a **Supabase Dashboard → Database → Backups**
2. Seleccionar el punto anterior a la migración problemática
3. Hacer "Restore" — esto baja toda la DB al estado anterior
4. Costo: se pierden los datos ingresados después del backup

**Opción B — Migración de rollback manual:**
Si la migración es reversible, escribe el SQL de rollback:
```sql
-- infra/supabase/migrations/TIMESTAMP_rollback_nombre_migracion.sql
-- DROP la columna, tabla, o cambio que causa el problema
```

**Regla de oro:** SIEMPRE haz un backup manual antes de aplicar migraciones en producción que modifiquen tablas existentes.

### Rollback completo (nuclear)

Si todo salió mal:
1. Rollback Railway → deployment anterior (2 minutos)
2. Rollback Vercel → deployment anterior (1 minuto)
3. Restaurar DB desde backup (5-10 minutos en Supabase Pro)

Total: ~15 minutos para volver al estado anterior.

---

## 12. Dominios y SSL

### DNS (en tu proveedor de dominio)

Agrega estos registros CNAME:

| Subdominio | Tipo | Destino |
|------------|------|---------|
| `app` | CNAME | `cname.vercel-dns.com` |
| `admin` | CNAME | `cname.vercel-dns.com` |
| `api` | CNAME | `<tu-servicio>.up.railway.app` |
| `api-admin` | CNAME | `<tu-servicio-admin>.up.railway.app` |
| `staging` | CNAME | `cname.vercel-dns.com` |
| `staging-admin` | CNAME | `cname.vercel-dns.com` |

### SSL

- **Vercel**: SSL automático (Let's Encrypt) para todos los dominios configurados
- **Railway**: SSL automático para dominios custom

No necesitas configurar SSL manualmente.

### IP Allowlist para el Admin

El panel de administración (`admin.olimpo.mx`) debe ser accesible solo desde IPs autorizadas. Hay dos capas de protección:

**Capa 1 — Middleware Next.js** (ya implementado en `apps/admin-web/middleware.ts`):
Agrega verificación de IP al middleware:
```typescript
const ALLOWED_IPS = process.env.ADMIN_ALLOWED_IPS?.split(',') ?? []

export function middleware(request: NextRequest) {
  const ip = request.headers.get('x-forwarded-for')?.split(',')[0]?.trim()
  
  if (ALLOWED_IPS.length > 0 && ip && !ALLOWED_IPS.includes(ip)) {
    return new Response('Acceso denegado', { status: 403 })
  }
  // ... resto del middleware existente
}
```

**Capa 2 — Variable de entorno en Vercel**:
```
ADMIN_ALLOWED_IPS=1.2.3.4,5.6.7.8
```

---

## 13. Monitoreo

### Sentry — errores

1. Crea un proyecto en [sentry.io](https://sentry.io) para Python (FastAPI) y uno para Next.js
2. Agrega el DSN a las variables de entorno:
   - API: `SENTRY_DSN=https://xxx@sentry.io/yyy` (ya configurado en config.py)
   - Web: `NEXT_PUBLIC_SENTRY_DSN=...` en Vercel

### Logfire — trazas FastAPI

1. Crea cuenta en [logfire.pydantic.dev](https://logfire.pydantic.dev)
2. Obtén tu token y agrégalo: `LOGFIRE_TOKEN=...`
3. Las trazas de cada request aparecen automáticamente (ya instrumentado en main.py)

### Verificaciones post-deploy

Después de cada deploy a producción, verifica:

```bash
# Health check de la API
curl https://api.olimpo.mx/health

# Respuesta esperada:
# {"status": "ok", "version": "0.1.0", "environment": "production"}
```

En el Supabase Dashboard, verifica que:
- Las migraciones aplicadas están en **Database → Migrations**
- No hay queries lentas en **Database → Query Performance**

---

## Resumen de secretos y variables necesarias

### GitHub Secrets (repositorio)

```
# Supabase
SUPABASE_ACCESS_TOKEN
SUPABASE_PROJECT_ID_PROD        = bqthpnflyqnrwjdxbnpk
SUPABASE_PROJECT_ID_STAGING     = <ref del proyecto staging>
SUPABASE_DB_PASSWORD_PROD       = <password DB producción>
SUPABASE_DB_PASSWORD_STAGING    = <password DB staging>

# Railway
RAILWAY_TOKEN                   = <token de Railway>

# Vercel
VERCEL_TOKEN                    = <token de Vercel>
VERCEL_ORG_ID                   = <orgId de .vercel/project.json>
VERCEL_WEB_PROJECT_ID           = <projectId de apps/web/.vercel/project.json>
VERCEL_ADMIN_PROJECT_ID         = <projectId de apps/admin-web/.vercel/project.json>
```

### Variables de entorno en Railway (por servicio y ambiente)

Ver `apps/api/.env.example` para la lista completa de variables necesarias en el servicio `olimpo-api`.

### Variables de entorno en Vercel (por proyecto)

```
# olimpo-web (producción)
NEXT_PUBLIC_SUPABASE_URL
NEXT_PUBLIC_SUPABASE_ANON_KEY
NEXT_PUBLIC_API_URL=https://api.olimpo.mx

# olimpo-admin-web (producción)
NEXT_PUBLIC_ADMIN_API_URL=https://api-admin.olimpo.mx
ADMIN_SESSION_SECRET
ADMIN_ALLOWED_IPS
```
