#!/bin/bash
# =============================================================================
# Olimpo — Railway Setup Script
# =============================================================================
# Este script automatiza la configuración inicial de Railway para Olimpo.
# Solo necesitas ejecutarlo UNA vez para configurar los servicios.
# =============================================================================

set -e

echo "========================================="
echo " Olimpo — Railway Setup"
echo "========================================="

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Check if Railway CLI is installed
if ! command -v railway &> /dev/null; then
    echo -e "${YELLOW}Railway CLI no está instalado. Instalando...${NC}"
    npm install -g @railway/cli
fi

# Check if logged in
echo ""
echo -e "${YELLOW}Verificando autenticación en Railway...${NC}"
railway whoami || {
    echo -e "${RED}No has iniciado sesión en Railway. Ejecuta 'railway login' primero.${NC}"
    exit 1
}

echo -e "${GREEN}✓ Autenticado correctamente${NC}"

# =============================================================================
# 1. Vincular al proyecto olimpo
# =============================================================================
echo ""
echo "========================================="
echo " Paso 1: Vincular al proyecto Railway"
echo "========================================="

echo "Buscando proyecto 'olimpo'..."
PROJECT_ID=$(railway project list --json 2>/dev/null | grep -o '"name":"olimpo"' | head -1 || echo "")

if [ -z "$PROJECT_ID" ]; then
    echo -e "${YELLOW}No se encontró proyecto 'olimpo'. Creando uno nuevo...${NC}"
    railway init --name olimpo
else
    echo -e "${GREEN}✓ Proyecto 'olimpo' encontrado${NC}"
fi

echo "Vinculando al proyecto..."
railway link --project olimpo || railway link

echo -e "${GREEN}✓ Proyecto vinculado${NC}"

# =============================================================================
# 2. Listar servicios existentes
# =============================================================================
echo ""
echo "========================================="
echo " Paso 2: Servicios en el proyecto"
echo "========================================="

railway service list --json

# =============================================================================
# 3. Crear servicios si no existen
# =============================================================================
echo ""
echo "========================================="
echo " Paso 3: Verificar/Crear servicios"
echo "========================================="

SERVICES=(
    "olimpo-api-staging:staging:apps/api"
    "olimpo-admin-staging:staging:apps/admin"
    "olimpo-api:production:apps/api"
    "olimpo-admin:production:apps/admin"
)

for svc_spec in "${SERVICES[@]}"; do
    IFS=':' read -r SERVICE_NAME ENVIRONMENT ROOT_DIR <<< "$svc_spec"

    echo ""
    echo -e "${YELLOW}Verificando servicio: $SERVICE_NAME ($ENVIRONMENT)${NC}"

    # Check if service exists
    SERVICE_EXISTS=$(railway service list --json 2>/dev/null | grep -c "\"name\":\"$SERVICE_NAME\"" || echo "0")

    if [ "$SERVICE_EXISTS" -eq "0" ]; then
        echo "   Creando servicio $SERVICE_NAME..."
        railway add --service "$SERVICE_NAME" --environment "$ENVIRONMENT"
        echo -e "${GREEN}   ✓ Servicio $SERVICE_NAME creado${NC}"
    else
        echo -e "${GREEN}   ✓ Servicio $SERVICE_NAME ya existe${NC}"
    fi

    # Link to the appropriate directory
    echo "   Configurando source directory: $ROOT_DIR"
    railway environment edit --service "$SERVICE_NAME" --service-config source.rootDirectory "$ROOT_DIR" --stage

done

# =============================================================================
# 4. Variables de entorno template
# =============================================================================
echo ""
echo "========================================="
echo " Paso 4: Plantilla de variables"
echo "========================================="
echo ""
echo "Para configurar las variables de entorno, usa los siguientes comandos:"
echo ""
echo "  # API Staging"
echo '  railway variable set ENVIRONMENT=staging --service olimpo-api-staging --environment staging'
echo '  railway variable set PORT=8000 --service olimpo-api-staging --environment staging'
echo '  railway variable set SUPABASE_URL=https://TU_REF_STAGING.supabase.co --service olimpo-api-staging --environment staging'
echo '  railway variable set SUPABASE_ANON_KEY=TU_KEY --service olimpo-api-staging --environment staging'
echo '  railway variable set SUPABASE_SERVICE_ROLE_KEY=TU_KEY --service olimpo-api-staging --environment staging'
echo ""
echo "  # Admin API Staging"
echo '  railway variable set ENVIRONMENT=staging --service olimpo-admin-staging --environment staging'
echo '  railway variable set PORT=8001 --service olimpo-admin-staging --environment staging'
echo '  railway variable set ADMIN_SUPABASE_URL=https://TU_REF_STAGING.supabase.co --service olimpo-admin-staging --environment staging'
echo '  railway variable set ADMIN_SUPABASE_SERVICE_ROLE_KEY=TU_KEY --service olimpo-admin-staging --environment staging'
echo ""
echo "  # API Production"
echo '  railway variable set ENVIRONMENT=production --service olimpo-api --environment production'
echo '  railway variable set PORT=8000 --service olimpo-api --environment production'
echo '  railway variable set SUPABASE_URL=https://TU_REF_PROD.supabase.co --service olimpo-api --environment production'
echo '  railway variable set SUPABASE_ANON_KEY=TU_KEY --service olimpo-api --environment production'
echo '  railway variable set SUPABASE_SERVICE_ROLE_KEY=TU_KEY --service olimpo-api --environment production'
echo ""
echo "  # Admin API Production"
echo '  railway variable set ENVIRONMENT=production --service olimpo-admin --environment production'
echo '  railway variable set PORT=8001 --service olimpo-admin --environment production'
echo '  railway variable set ADMIN_SUPABASE_URL=https://TU_REF_PROD.supabase.co --service olimpo-admin --environment production'
echo '  railway variable set ADMIN_SUPABASE_SERVICE_ROLE_KEY=TU_KEY --service olimpo-admin --environment production'
echo ""

# =============================================================================
# 5. Dominios custom
# =============================================================================
echo ""
echo "========================================="
echo " Paso 5: Configurar dominios custom"
echo "========================================="
echo ""
echo "Después de que los servicios estén desplegados, configura los dominios:"
echo ""
echo "  railway domain staging-api.olimpo.mx --service olimpo-api-staging --environment staging"
echo "  railway domain staging-admin-api.olimpo.mx --service olimpo-admin-staging --environment staging"
echo "  railway domain api.olimpo.mx --service olimpo-api --environment production"
echo "  railway domain api-admin.olimpo.mx --service olimpo-admin --environment production"
echo ""
echo "Luego en Squarespace, configura los CNAME records:"
echo "  staging-api     → olimpo-api-staging.up.railway.app"
echo "  staging-admin-api → olimpo-admin-staging.up.railway.app"
echo "  api             → olimpo-api.up.railway.app"
echo "  api-admin       → olimpo-admin.up.railway.app"
echo ""

# =============================================================================
# 6. Deployment inicial
# =============================================================================
echo ""
echo "========================================="
echo " Paso 6: Deployment inicial"
echo "========================================="
echo ""
echo -e "${YELLOW}¿Quieres hacer el primer deployment ahora? (y/n)${NC}"
read -r response

if [[ "$response" =~ ^y$ ]]; then
    echo "Haciendo deploy de API staging..."
    cd apps/api && railway up --service olimpo-api-staging --environment staging --detach && cd ../..

    echo "Haciendo deploy de Admin API staging..."
    cd apps/admin && railway up --service olimpo-admin-staging --environment staging --detach && cd ../..

    echo -e "${GREEN}Deployments iniciados. Revisa el dashboard de Railway para ver el progreso.${NC}"
else
    echo "Puedes hacer el deploy manualmente más tarde con:"
    echo "  cd apps/api && railway up --service olimpo-api-staging --environment staging --detach"
fi

echo ""
echo "========================================="
echo -e "${GREEN} Setup completo!"
echo "========================================="
echo ""
echo "Próximos pasos:"
echo "1. Configurar variables de entorno en el dashboard de Railway"
echo "2. Hacer el primer deployment manualmente"
echo "3. Configurar dominios custom en Squarespace"
echo "4. Agregar RAILWAY_TOKEN a GitHub Secrets"
echo "5. Probar el workflow de deploy-staging"