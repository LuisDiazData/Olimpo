# Olimpo — Guía de Deploy Paso a Paso (2025)

> Guía concisa y actualizada para poner Olimpo en producción.

---

## 1. GitHub

```bash
cd /Users/luisdiaz/Documents/Tamis/Olimpo

# Verificar estado
git status

# Asegurar que tienes remote
git remote -v

# Si no tienes .gitignore, créalo (ya existe en este proyecto)

# Hacer push a main (ya tienes branch fix/vercel-eslint-deploy)
git checkout main
git push -u origin main

# Crear y pushar develop
git checkout -b develop
git push -u origin develop
```

---

## 2. Supabase

```bash
# Instalar CLI si no la tienes
brew install supabase/tap/supabase

# Login
supabase login

# Enlazar proyecto producción (ya existe)
supabase link --project-ref bqthpnflyqnrwjdxbnpk

# Aplicar migraciones (tienes 34 en infra/supabase/migrations/)
cd infra/supabase
supabase db push
```

---

## 3. Railway (Backend)

```bash
# Instalar CLI
npm install -g @railway/cli

# Login
railway login

# Deploy API
cd apps/api
railway up --detached

# Variables de entorno (reemplaza con tus valores reales)
railway variables set SUPABASE_URL="https://bqthpnflyqnrwjdxbnpk.supabase.co"
railway variables set SUPABASE_SERVICE_ROLE_KEY="your-service-role-key"
railway variables set OPENAI_API_KEY="sk-..."
railway variables set ANTHROPIC_API_KEY="sk-ant-..."
railway variables set RUNPOD_API_KEY="..."
railway variables set RUNPOD_ENDPOINT_OCR="https://api.runpod.ai/v2/..."
railway variables set LOGFIRE_TOKEN="..."
railway variables set SENTRY_DSN="..."
railway variables set CORS_ORIGINS="https://app.olimpo.mx,https://admin.olimpo.mx"

# Deploy Admin API
cd apps/admin
railway up --detached

# Configurar dominio
railway domain add api.olimpo.mx
```

---

## 4. Vercel (Frontend)

```bash
# Instalar CLI
npm i -g vercel

# Login
vercel login

# Deploy web
cd apps/web
vercel --prod

# Deploy admin-web
cd apps/admin-web
vercel --prod

# Configurar variables en dashboard de Vercel:
# apps/web:
#   NEXT_PUBLIC_SUPABASE_URL = https://bqthpnflyqnrwjdxbnpk.supabase.co
#   NEXT_PUBLIC_SUPABASE_ANON_KEY = eyJ...
#   NEXT_PUBLIC_API_URL = https://api.olimpo.mx
#
# apps/admin-web:
#   NEXT_PUBLIC_ADMIN_API_URL = https://api-admin.olimpo.mx
```

---

## 5. RunPod (OCR)

```bash
# Ya tienes credenciales, solo configurar en Railway:
railway variables set RUNPOD_API_KEY="..."
railway variables set RUNPOD_ENDPOINT_OCR="https://api.runpod.ai/v2/your-endpoint"
```

---

## 6. DNS

```
app.olimpo.mx      → CNAME → cname.vercel-dns.com
admin.olimpo.mx    → CNAME → cname.vercel-dns.com
api.olimpo.mx      → CNAME → your-railway-api.railway.app
```

---

## 7. Pipeline CI/CD Automático

```bash
# Push a develop → deploy automático a staging
git push origin develop

# Push a main → deploy automático a producción (con approval gate)
git push origin main
```

---

## Checklist Pre-Deploy

- [ ] GitHub: ¿Pushaste el código?
- [ ] Supabase: ¿Migraciones aplicadas?
- [ ] Railway: ¿APIs deployadas con vars?
- [ ] Vercel: ¿Web apps deployadas con vars?
- [ ] RunPod: ¿Endpoint OCR configurado?
- [ ] DNS: ¿Registros creados?
- [ ] GitHub Secrets: ¿Configurados?

---

## URLs Esperadas

| Servicio | Producción | Staging |
|----------|-----------|---------|
| Web | app.olimpo.mx | staging.olimpo.mx |
| Admin Web | admin.olimpo.mx | staging-admin.olimpo.mx |
| API | api.olimpo.mx | staging-api.olimpo.mx |
| Supabase | bqthpnflyqnrwjdxbnpk.supabase.co | (crear branch) |