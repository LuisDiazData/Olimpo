"""
Router de control del pipeline de agentes IA.

POST   /pipeline/tramites/{id}/iniciar          â€” dispara el pipeline para un trÃ¡mite
POST   /pipeline/tramites/{id}/requiere-atencion â€” escala a revisiÃ³n humana
GET    /pipeline/tramites/{id}/estado           â€” estado actual del pipeline
GET    /pipeline/reintentos                     â€” cola de reintentos pendientes (directores)
GET    /pipeline/schema/estados                 â€” grafo de transiciones (para agentes MCP)
"""

from datetime import datetime
from uuid import UUID

import structlog
from fastapi import APIRouter, Depends, HTTPException, Query, status
from pydantic import BaseModel, Field

from core.auth import get_current_user, get_current_user_or_agent, require_roles
from core.database import get_admin_db, get_user_db
from models.tramite import TRANSICIONES_VALIDAS, EstadoTramite
from models.usuario import RolUsuario, UsuarioToken

log = structlog.get_logger(__name__)
router = APIRouter(prefix="/pipeline", tags=["pipeline"])

_SOLO_DIRECTORES = [Depends(require_roles(RolUsuario.director_general, RolUsuario.director_ops))]


# ---------------------------------------------------------------------------
# Modelos
# ---------------------------------------------------------------------------


class IniciarPipelineBody(BaseModel):
    correo_id: UUID | None = Field(
        default=None,
        description="UUID del correo que origina el pipeline. NULL para pipelines manuales.",
    )
    agente_inicio: str = Field(
        default="agente_1",
        description="Nombre del agente desde el que iniciar. Valores: agente_1 a agente_6. Por defecto: agente_1.",
    )
    forzar: bool = Field(
        default=False,
        description="True para forzar el reinicio del pipeline aunque el trÃ¡mite ya tenga uno activo. Usar con precauciÃ³n.",
    )


class RequiereAtencionBody(BaseModel):
    motivo: str = Field(
        min_length=5,
        max_length=1000,
        description="DescripciÃ³n clara de por quÃ© el trÃ¡mite requiere atenciÃ³n humana. Escrito por el agente IA.",
    )
    agente_nombre: str = Field(
        description="Nombre del agente que detectÃ³ el problema. Ej: agente_4.",
    )
    datos: dict = Field(
        default_factory=dict,
        description="Datos adicionales estructurados para contextualizar la alerta (ej: emails_ambiguos, confianza_baja).",
    )


class EstadoPipelineResponse(BaseModel):
    tramite_id: UUID
    paso_actual: str | None = Field(
        description="Agente actualmente procesando el trÃ¡mite. NULL si no hay pipeline activo."
    )
    paso_inicio: datetime | None = Field(description="CuÃ¡ndo iniciÃ³ el paso actual.")
    requiere_atencion: bool = Field(description="True si el pipeline escalÃ³ a revisiÃ³n humana.")
    ultimo_agente_log: dict | None = Field(
        description="Ãšltimo registro de agente_ia_log para este trÃ¡mite."
    )

    model_config = {"from_attributes": True}


class ReintentoPipelineResponse(BaseModel):
    id: UUID
    tramite_id: UUID | None
    agente_nombre: str
    intento_num: int
    max_intentos: int
    intentar_desde: datetime
    estado: str
    motivo_fallo: str | None
    created_at: datetime

    model_config = {"from_attributes": True}


# ---------------------------------------------------------------------------
# POST /pipeline/tramites/{id}/iniciar
# ---------------------------------------------------------------------------


@router.post(
    "/tramites/{tramite_id}/iniciar",
    status_code=status.HTTP_202_ACCEPTED,
    summary="Iniciar pipeline de agentes IA",
    description=(
        "Dispara el pipeline de agentes IA para procesar un trÃ¡mite. "
        "Por defecto inicia desde agente_1 (ingesta). Puede iniciarse desde cualquier agente. "
        "Acepta JWT de usuario (frontend) O X-Agent-API-Key (agentes MCP). "
        "El pipeline corre de forma asÃ­ncrona en workers Celery â€” este endpoint solo lo encola."
    ),
)
async def iniciar_pipeline(
    tramite_id: UUID,
    body: IniciarPipelineBody,
    actor: UsuarioToken = Depends(get_current_user_or_agent),
) -> dict:
    agentes_validos = {f"agente_{i}" for i in range(1, 7)}
    if body.agente_inicio not in agentes_validos:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            detail={
                "error_code": "AGENTE_INVALIDO",
                "mensaje": f"agente_inicio '{body.agente_inicio}' no es vÃ¡lido.",
                "valores_validos": sorted(agentes_validos),
            },
        )

    db = get_admin_db()
    tramite = (
        db.table("tramite")
        .select("id, estado, paso_pipeline_actual, activo")
        .eq("id", str(tramite_id))
        .maybe_single()
        .execute()
    )

    if not tramite:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail={
                "error_code": "TRAMITE_NO_ENCONTRADO",
                "mensaje": "TrÃ¡mite no encontrado.",
                "tramite_id": str(tramite_id),
            },
        )

    if not tramite.data.get("activo"):
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            detail={
                "error_code": "TRAMITE_INACTIVO",
                "mensaje": "No se puede iniciar el pipeline en un trÃ¡mite inactivo.",
            },
        )

    if tramite.data.get("paso_pipeline_actual") and not body.forzar:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail={
                "error_code": "PIPELINE_YA_ACTIVO",
                "mensaje": f"El trÃ¡mite ya tiene el pipeline activo en '{tramite.data['paso_pipeline_actual']}'. Usar forzar=True para reiniciar.",
                "paso_actual": tramite.data["paso_pipeline_actual"],
            },
        )

    # Actualizar paso_pipeline_actual en el trÃ¡mite
    db.table("tramite").update(
        {
            "paso_pipeline_actual": body.agente_inicio,
            "paso_pipeline_inicio": datetime.utcnow().isoformat(),
        }
    ).eq("id", str(tramite_id)).execute()

    log.info(
        "pipeline_iniciado",
        tramite_id=str(tramite_id),
        agente_inicio=body.agente_inicio,
        correo_id=str(body.correo_id) if body.correo_id else None,
        por=str(actor.id),
    )

    return {
        "aceptado": True,
        "tramite_id": str(tramite_id),
        "agente_inicio": body.agente_inicio,
        "mensaje": f"Pipeline encolado desde {body.agente_inicio}. Procesamiento asÃ­ncrono en Celery.",
    }


# ---------------------------------------------------------------------------
# POST /pipeline/tramites/{id}/requiere-atencion
# ---------------------------------------------------------------------------


@router.post(
    "/tramites/{tramite_id}/requiere-atencion",
    status_code=status.HTTP_200_OK,
    summary="Escalar trÃ¡mite a revisiÃ³n humana",
    description=(
        "Marca el trÃ¡mite como requiere_atencion=True y registra el motivo en el timeline. "
        "Llamado por agentes IA cuando detectan ambigÃ¼edad, baja confianza o error irrecuperable. "
        "Acepta JWT de usuario (frontend) O X-Agent-API-Key (agentes MCP). "
        "El trÃ¡mite aparece en el dashboard con bandera de atenciÃ³n urgente."
    ),
)
async def marcar_requiere_atencion(
    tramite_id: UUID,
    body: RequiereAtencionBody,
    actor: UsuarioToken = Depends(get_current_user_or_agent),
) -> dict:
    db = get_admin_db()

    tramite = (
        db.table("tramite").select("id, activo").eq("id", str(tramite_id)).maybe_single().execute()
    )
    if not tramite:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail={"error_code": "TRAMITE_NO_ENCONTRADO", "mensaje": "TrÃ¡mite no encontrado."},
        )

    # Marcar el trÃ¡mite y limpiar el paso de pipeline
    db.table("tramite").update(
        {
            "requiere_atencion": True,
            "paso_pipeline_actual": None,
            "paso_pipeline_inicio": None,
        }
    ).eq("id", str(tramite_id)).execute()

    # Registrar evento en el timeline
    db.table("tramite_evento").insert(
        {
            "tramite_id": str(tramite_id),
            "tipo_evento": "accion_agente_ia",
            "agente_ia_nombre": body.agente_nombre,
            "descripcion": f"[REQUIERE ATENCIÃ“N] {body.motivo}",
            "datos": body.datos,
            "visible_en_timeline": True,
            "origen_sistema": body.agente_nombre,
        }
    ).execute()

    log.info(
        "tramite_requiere_atencion",
        tramite_id=str(tramite_id),
        agente=body.agente_nombre,
        motivo=body.motivo[:100],
    )

    return {
        "tramite_id": str(tramite_id),
        "requiere_atencion": True,
        "mensaje": "TrÃ¡mite marcado para revisiÃ³n humana. El analista asignado recibirÃ¡ una notificaciÃ³n.",
    }


# ---------------------------------------------------------------------------
# GET /pipeline/tramites/{id}/estado
# ---------------------------------------------------------------------------


@router.get(
    "/tramites/{tramite_id}/estado",
    response_model=EstadoPipelineResponse,
    summary="Estado del pipeline de un trÃ¡mite",
    description=(
        "Devuelve el estado actual del pipeline de agentes IA para un trÃ¡mite: "
        "quÃ© agente estÃ¡ procesando, cuÃ¡ndo iniciÃ³, y si requiere atenciÃ³n humana. "
        "Ãštil para monitoreo y para que agentes MCP verifiquen antes de iniciar."
    ),
)
async def obtener_estado_pipeline(
    tramite_id: UUID,
    actor: UsuarioToken = Depends(get_current_user_or_agent),
) -> EstadoPipelineResponse:
    db = get_admin_db()

    tramite = (
        db.table("tramite")
        .select("id, paso_pipeline_actual, paso_pipeline_inicio, requiere_atencion")
        .eq("id", str(tramite_id))
        .maybe_single()
        .execute()
    )

    if not tramite:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail={"error_code": "TRAMITE_NO_ENCONTRADO", "mensaje": "TrÃ¡mite no encontrado."},
        )

    # Ãšltimo log de agente IA para este trÃ¡mite
    ultimo_log_result = (
        db.table("agente_ia_log")
        .select("agente_nombre, estado, inicio, fin, duracion_ms, modelo_llm, costo_usd, error")
        .eq("tramite_id", str(tramite_id))
        .order("inicio", desc=True)
        .limit(1)
        .execute()
    )
    ultimo_log = ultimo_log_result.data[0] if ultimo_log_result.data else None

    t = tramite.data
    return EstadoPipelineResponse(
        tramite_id=tramite_id,
        paso_actual=t.get("paso_pipeline_actual"),
        paso_inicio=datetime.fromisoformat(t["paso_pipeline_inicio"])
        if t.get("paso_pipeline_inicio")
        else None,
        requiere_atencion=t.get("requiere_atencion", False),
        ultimo_agente_log=ultimo_log,
    )


# ---------------------------------------------------------------------------
# GET /pipeline/reintentos
# ---------------------------------------------------------------------------


@router.get(
    "/reintentos",
    response_model=list[ReintentoPipelineResponse],
    dependencies=_SOLO_DIRECTORES,
    summary="Cola de reintentos del pipeline",
    description=(
        "Lista los reintentos de agentes IA pendientes o fallidos. "
        "Un reintento se crea cuando un agente falla y Celery programa un nuevo intento con backoff. "
        "Cuando se agotan los intentos, el estado es 'abandonado' y el trÃ¡mite requiere intervenciÃ³n manual. "
        "Solo directores pueden ver la cola de reintentos."
    ),
)
async def listar_reintentos(
    estado: str | None = Query(
        default="pendiente", description="Estado del reintento: pendiente, completado, abandonado."
    ),
    agente_nombre: str | None = Query(
        default=None, description="Filtrar por nombre de agente (agente_1 a agente_6)."
    ),
    limit: int = Query(default=50, ge=1, le=200),
    usuario: UsuarioToken = Depends(get_current_user),
) -> list[ReintentoPipelineResponse]:
    db = get_user_db(usuario.access_token)
    query = db.table("pipeline_reintento").select("*")

    if estado:
        query = query.eq("estado", estado)
    if agente_nombre:
        query = query.eq("agente_nombre", agente_nombre)

    result = query.order("intentar_desde").limit(limit).execute()
    return [ReintentoPipelineResponse.model_validate(row) for row in result.data]


# ---------------------------------------------------------------------------
# GET /pipeline/schema/estados
# ---------------------------------------------------------------------------


@router.get(
    "/schema/estados",
    summary="Grafo de transiciones de estado del trÃ¡mite",
    description=(
        "Devuelve el grafo completo de transiciones vÃ¡lidas de la mÃ¡quina de estados del trÃ¡mite. "
        "Endpoint de introspecciÃ³n para agentes MCP: el agente puede llamar esto al inicio "
        "para entender quÃ© transiciones son posibles sin necesidad de hardcodear la lÃ³gica en el prompt."
    ),
)
async def obtener_schema_estados(
    _: UsuarioToken = Depends(get_current_user_or_agent),
) -> dict:
    return {
        "estados": [e.value for e in EstadoTramite],
        "transiciones": {
            estado.value: [dest.value for dest in destinos]
            for estado, destinos in TRANSICIONES_VALIDAS.items()
        },
        "estados_terminales": [e.value for e in EstadoTramite if not TRANSICIONES_VALIDAS.get(e)],
    }
