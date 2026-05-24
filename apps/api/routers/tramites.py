"""
Router de trÃ¡mites â€” entidad central del CRM Olimpo.

GET    /tramites                       â€” dashboard (RLS filtra por rol)
POST   /tramites                       â€” crear trÃ¡mite manual
GET    /tramites/{id}                  â€” detalle completo con transiciones disponibles
PATCH  /tramites/{id}                  â€” actualizar campos libres
POST   /tramites/{id}/cambiar-estado   â€” transiciÃ³n de la mÃ¡quina de estados
POST   /tramites/{id}/asignar          â€” asignar analista
GET    /tramites/{id}/eventos          â€” timeline del trÃ¡mite
POST   /tramites/{id}/eventos          â€” agregar nota interna
"""

from uuid import UUID

import structlog
from fastapi import APIRouter, Depends, HTTPException, Query, status

from core.auth import get_current_user, require_roles
from core.database import get_user_db
from models.pagination import PaginatedResponse
from models.tramite import (
    AgregarNotaBody,
    AsignarAnalistaBody,
    CambiarEstadoBody,
    EstadoTramite,
    EventoResponse,
    TipoEventoTramite,
    TRANSICIONES_VALIDAS,
    TramiteCreate,
    TramiteListItem,
    TramiteResponse,
    TramiteUpdate,
)
from models.usuario import RolUsuario, UsuarioToken

log = structlog.get_logger(__name__)
router = APIRouter(prefix="/tramites", tags=["tramites"])

_GERENTES_Y_DIRECTORES = [
    Depends(require_roles(RolUsuario.director_general, RolUsuario.director_ops, RolUsuario.gerente))
]


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _get_tramite_o_404(db, tramite_id: UUID) -> dict:
    result = (
        db.table("tramite")
        .select("id, estado, analista_id, ramo, activo, folio_ot")
        .eq("id", str(tramite_id))
        .maybe_single()
        .execute()
    )
    if not result:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail={"error_code": "TRAMITE_NO_ENCONTRADO", "mensaje": "TrÃ¡mite no encontrado.", "tramite_id": str(tramite_id)},
        )
    return result.data


def _enriquecer_tramite(data: dict) -> dict:
    """Aplana los JOINs anidados de Supabase en campos planos del modelo."""
    if agente := (data.pop("agente", None) or {}):
        data["agente_nombre"] = agente.get("nombre")
        data["agente_cua"] = agente.get("cua")
    else:
        data["agente_nombre"] = None
        data["agente_cua"] = None

    if analista := (data.pop("usuario", None) or {}):
        data["analista_nombre"] = analista.get("nombre")
    else:
        data["analista_nombre"] = None

    if poliza := (data.pop("poliza", None) or {}):
        data["poliza_numero"] = poliza.get("numero_poliza")
    else:
        data["poliza_numero"] = None

    if asegurado := (data.pop("asegurado", None) or {}):
        data["asegurado_nombre"] = asegurado.get("nombre")
    else:
        data["asegurado_nombre"] = None

    # Agregar transiciones disponibles segÃºn estado actual
    try:
        estado_actual = EstadoTramite(data.get("estado", ""))
        data["transiciones_disponibles"] = [e.value for e in TRANSICIONES_VALIDAS.get(estado_actual, [])]
    except ValueError:
        data["transiciones_disponibles"] = []

    return data


# ---------------------------------------------------------------------------
# GET /tramites
# ---------------------------------------------------------------------------

@router.get(
    "",
    response_model=PaginatedResponse[TramiteListItem],
    summary="Listar trÃ¡mites",
    description=(
        "Devuelve los trÃ¡mites accesibles segÃºn el rol del usuario autenticado. "
        "RLS garantiza: directores ven todos, gerentes ven su ramo, analistas ven solo sus trÃ¡mites. "
        "Soporta filtros por estado, ramo, analista, agente y bÃºsqueda de texto en folio/tÃ­tulo. "
        "Respuesta paginada â€” usar offset+limit para navegar. Ordenado por ultima_actividad desc."
    ),
)
async def listar_tramites(
    estado: EstadoTramite | None = Query(default=None, description="Filtrar por estado de la mÃ¡quina de estados."),
    ramo: str | None = Query(default=None, description="Filtrar por ramo (vida, autos, gmm, danos, etc.)."),
    analista_id: UUID | None = Query(default=None, description="UUID del analista asignado al trÃ¡mite."),
    agente_id: UUID | None = Query(default=None, description="UUID del agente de seguros que originÃ³ el trÃ¡mite."),
    requiere_atencion: bool | None = Query(default=None, description="True para ver solo trÃ¡mites con bandera de atenciÃ³n urgente."),
    q: str | None = Query(default=None, description="BÃºsqueda de texto libre en folio y tÃ­tulo del trÃ¡mite."),
    activo: bool = Query(default=True, description="False para incluir trÃ¡mites archivados/inactivos."),
    limit: int = Query(default=50, ge=1, le=200, description="MÃ¡ximo de registros por pÃ¡gina (1-200)."),
    offset: int = Query(default=0, ge=0, description="NÃºmero de registros a saltar para paginaciÃ³n."),
    usuario: UsuarioToken = Depends(get_current_user),
) -> PaginatedResponse[TramiteListItem]:
    db = get_user_db(usuario.access_token)

    base_select = (
        "id, folio, folio_ot, tipo_tramite, estado, prioridad, ramo, titulo, "
        "requiere_atencion, analista_id, agente_id, fecha_recepcion, "
        "fecha_limite_sla, ultima_actividad, etiquetas, "
        "agente!left(nombre, cua), "
        "usuario!tramite_analista_id_fkey!left(nombre)"
    )

    def _apply_filters(q_builder):
        q_builder = q_builder.eq("activo", activo)
        if estado:
            q_builder = q_builder.eq("estado", estado.value)
        if ramo:
            q_builder = q_builder.eq("ramo", ramo)
        if analista_id:
            q_builder = q_builder.eq("analista_id", str(analista_id))
        if agente_id:
            q_builder = q_builder.eq("agente_id", str(agente_id))
        if requiere_atencion is not None:
            q_builder = q_builder.eq("requiere_atencion", requiere_atencion)
        if q:
            q_builder = q_builder.or_(f"folio.ilike.%{q}%,titulo.ilike.%{q}%")
        return q_builder

    # Contar total para metadatos de paginaciÃ³n
    count_query = _apply_filters(db.table("tramite").select("id", count="exact"))
    count_result = count_query.execute()
    total = count_result.count or 0

    # Obtener pÃ¡gina
    data_query = _apply_filters(db.table("tramite").select(base_select))
    result = (
        data_query
        .order("ultima_actividad", desc=True)
        .range(offset, offset + limit - 1)
        .execute()
    )

    items = [TramiteListItem.model_validate(_enriquecer_tramite(row)) for row in result.data]
    return PaginatedResponse.build(items=items, total=total, offset=offset, limit=limit)


# ---------------------------------------------------------------------------
# POST /tramites
# ---------------------------------------------------------------------------

@router.post(
    "",
    response_model=TramiteResponse,
    status_code=status.HTTP_201_CREATED,
    summary="Crear trÃ¡mite manual",
    description=(
        "Crea un nuevo trÃ¡mite en estado 'recibido'. "
        "El folio se genera automÃ¡ticamente por trigger de base de datos. "
        "El primer evento del timeline (creacion) se registra tambiÃ©n por trigger. "
        "Para trÃ¡mites originados por email, el Agente 4 llama este endpoint con canal_origen='email'."
    ),
)
async def crear_tramite(
    body: TramiteCreate,
    usuario: UsuarioToken = Depends(get_current_user),
) -> TramiteResponse:
    db = get_user_db(usuario.access_token)

    payload = body.model_dump(exclude_none=True)
    for key in ("agente_id", "poliza_id", "asegurado_id", "analista_id"):
        if key in payload:
            payload[key] = str(payload[key])
    if "ramo" in payload:
        payload["ramo"] = str(payload["ramo"])

    payload.pop("folio", None)

    result = (
        db.table("tramite")
        .insert(payload)
        .select(
            "*, agente!left(nombre, cua), "
            "usuario!tramite_analista_id_fkey!left(nombre), "
            "poliza!left(numero_poliza), "
            "asegurado!left(nombre)"
        )
        .execute()
    )
    if result.data:
        result.data = result.data[0]

    data = _enriquecer_tramite(result.data)
    log.info("tramite_creado", folio=data["folio"], tipo=body.tipo_tramite, por=str(usuario.id))
    return TramiteResponse.model_validate(data)


# ---------------------------------------------------------------------------
# GET /tramites/{id}
# ---------------------------------------------------------------------------

@router.get(
    "/{tramite_id}",
    response_model=TramiteResponse,
    summary="Obtener trÃ¡mite",
    description=(
        "Devuelve el detalle completo del trÃ¡mite incluyendo relaciones (agente, analista, pÃ³liza, asegurado). "
        "El campo 'transiciones_disponibles' lista los estados a los que puede transicionar "
        "desde su estado actual â€” Ãºtil para agentes MCP que no conocen la mÃ¡quina de estados."
    ),
)
async def obtener_tramite(
    tramite_id: UUID,
    usuario: UsuarioToken = Depends(get_current_user),
) -> TramiteResponse:
    db = get_user_db(usuario.access_token)

    result = (
        db.table("tramite")
        .select(
            "*, agente!left(nombre, cua), "
            "usuario!tramite_analista_id_fkey!left(nombre), "
            "poliza!left(numero_poliza), "
            "asegurado!left(nombre)"
        )
        .eq("id", str(tramite_id))
        .maybe_single()
        .execute()
    )

    if not result:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail={"error_code": "TRAMITE_NO_ENCONTRADO", "mensaje": "TrÃ¡mite no encontrado.", "tramite_id": str(tramite_id)},
        )

    return TramiteResponse.model_validate(_enriquecer_tramite(result.data))


# ---------------------------------------------------------------------------
# PATCH /tramites/{id}
# ---------------------------------------------------------------------------

@router.patch(
    "/{tramite_id}",
    response_model=TramiteResponse,
    summary="Actualizar campos del trÃ¡mite",
    description=(
        "Actualiza campos libres del trÃ¡mite: tÃ­tulo, descripciÃ³n, prioridad, agente vinculado, etc. "
        "No gestiona la mÃ¡quina de estados â€” usar POST /cambiar-estado para transiciones. "
        "RLS garantiza que el analista solo puede editar sus propios trÃ¡mites."
    ),
)
async def actualizar_tramite(
    tramite_id: UUID,
    body: TramiteUpdate,
    usuario: UsuarioToken = Depends(get_current_user),
) -> TramiteResponse:
    cambios = body.model_dump(exclude_none=True)
    if not cambios:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            detail={"error_code": "SIN_CAMBIOS", "mensaje": "No se enviaron campos para actualizar."},
        )

    db = get_user_db(usuario.access_token)
    _get_tramite_o_404(db, tramite_id)

    for key in ("agente_id", "poliza_id", "asegurado_id"):
        if key in cambios:
            cambios[key] = str(cambios[key])

    db.table("tramite").update(cambios).eq("id", str(tramite_id)).execute()
    return await obtener_tramite(tramite_id, usuario)


# ---------------------------------------------------------------------------
# POST /tramites/{id}/cambiar-estado
# ---------------------------------------------------------------------------

@router.post(
    "/{tramite_id}/cambiar-estado",
    response_model=TramiteResponse,
    summary="Cambiar estado del trÃ¡mite",
    description=(
        "Ejecuta una transiciÃ³n de estado en la mÃ¡quina de estados del trÃ¡mite. "
        "Solo se permiten transiciones vÃ¡lidas (ver campo 'transiciones_disponibles' en GET /{id}). "
        "El trigger de base de datos registra el evento en el timeline automÃ¡ticamente. "
        "Requiere 'motivo_rechazo_gnp' cuando estado_nuevo='rechazado'. "
        "Acepta 'folio_ot' para registrar el nÃºmero de OT al turnar a GNP."
    ),
)
async def cambiar_estado(
    tramite_id: UUID,
    body: CambiarEstadoBody,
    usuario: UsuarioToken = Depends(get_current_user),
) -> TramiteResponse:
    db = get_user_db(usuario.access_token)
    tramite = _get_tramite_o_404(db, tramite_id)

    estado_actual = EstadoTramite(tramite["estado"])
    destinos_validos = TRANSICIONES_VALIDAS.get(estado_actual, [])

    if body.estado_nuevo not in destinos_validos:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            detail={
                "error_code": "TRANSICION_INVALIDA",
                "mensaje": f"TransiciÃ³n invÃ¡lida: '{estado_actual}' â†’ '{body.estado_nuevo}'.",
                "estado_actual": estado_actual.value,
                "estado_solicitado": body.estado_nuevo.value,
                "transiciones_validas": [e.value for e in destinos_validos] or [],
            },
        )

    if body.estado_nuevo == EstadoTramite.rechazado and not body.motivo_rechazo_gnp:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            detail={
                "error_code": "MOTIVO_REQUERIDO",
                "mensaje": "Se requiere 'motivo_rechazo_gnp' para transicionar a 'rechazado'.",
            },
        )

    if body.estado_nuevo == EstadoTramite.pendiente_documentos and not body.motivo:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            detail={
                "error_code": "MOTIVO_REQUERIDO",
                "mensaje": "Se requiere 'motivo' para transicionar a 'pendiente_documentos' (documenta quÃ© falta).",
            },
        )

    actualizaciones: dict = {"estado": body.estado_nuevo.value}

    if body.motivo_rechazo_gnp:
        actualizaciones["motivo_rechazo_gnp"] = body.motivo_rechazo_gnp
    if body.folio_ot:
        actualizaciones["folio_ot"] = body.folio_ot

    if body.estado_nuevo == EstadoTramite.turnado_gnp:
        from datetime import date
        actualizaciones["ot_fecha_envio"] = date.today().isoformat()

    if body.estado_nuevo in (EstadoTramite.aprobado, EstadoTramite.rechazado):
        from datetime import date
        actualizaciones["ot_fecha_respuesta"] = date.today().isoformat()

    db.table("tramite").update(actualizaciones).eq("id", str(tramite_id)).execute()

    # Control de SLAs
    if body.estado_nuevo == EstadoTramite.en_proceso_gnp:
        db.rpc("pausar_sla_tramite", {"p_tramite_id": str(tramite_id)}).execute()
    elif estado_actual == EstadoTramite.en_proceso_gnp and body.estado_nuevo != EstadoTramite.en_proceso_gnp:
        db.rpc("reanudar_sla_tramite", {"p_tramite_id": str(tramite_id)}).execute()

    if body.estado_nuevo in (EstadoTramite.aprobado, EstadoTramite.rechazado):
        db.rpc("cerrar_sla_tramite", {"p_tramite_id": str(tramite_id)}).execute()

    log.info(
        "tramite_estado_cambiado",
        tramite_id=str(tramite_id),
        de=estado_actual.value,
        a=body.estado_nuevo.value,
        por=str(usuario.id),
    )
    return await obtener_tramite(tramite_id, usuario)


# ---------------------------------------------------------------------------
# POST /tramites/{id}/asignar
# ---------------------------------------------------------------------------

@router.post(
    "/{tramite_id}/asignar",
    response_model=TramiteResponse,
    dependencies=_GERENTES_Y_DIRECTORES,
    summary="Asignar analista al trÃ¡mite",
    description=(
        "Asigna o reasigna el analista responsable del trÃ¡mite. "
        "El trigger asigna automÃ¡ticamente el gerente_id segÃºn el ramo del analista. "
        "Gerentes solo pueden asignar analistas de su propio ramo. "
        "El evento de asignaciÃ³n se registra en el timeline automÃ¡ticamente."
    ),
)
async def asignar_analista(
    tramite_id: UUID,
    body: AsignarAnalistaBody,
    usuario: UsuarioToken = Depends(get_current_user),
) -> TramiteResponse:
    db = get_user_db(usuario.access_token)

    if usuario.rol == RolUsuario.gerente:
        analista = (
            db.table("usuario")
            .select("ramo, rol, activo")
            .eq("id", str(body.analista_id))
            .maybe_single()
            .execute()
        )
        if not analista:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail={"error_code": "ANALISTA_NO_ENCONTRADO", "mensaje": "Analista no encontrado.", "analista_id": str(body.analista_id)},
            )
        if analista.data.get("rol") != "analista":
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
                detail={"error_code": "ROL_INCORRECTO", "mensaje": "Solo se puede asignar a usuarios con rol 'analista'."},
            )
        if usuario.ramo and analista.data.get("ramo") != usuario.ramo.value:
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail={
                    "error_code": "RAMO_INCORRECTO",
                    "mensaje": "Solo puedes asignar analistas de tu propio ramo.",
                    "tu_ramo": usuario.ramo.value,
                    "ramo_analista": analista.data.get("ramo"),
                },
            )
        if not analista.data.get("activo"):
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
                detail={"error_code": "ANALISTA_INACTIVO", "mensaje": "El analista seleccionado estÃ¡ inactivo.", "analista_id": str(body.analista_id)},
            )

    _get_tramite_o_404(db, tramite_id)
    db.table("tramite").update({"analista_id": str(body.analista_id)}).eq("id", str(tramite_id)).execute()

    # Activar SLA del trámite al asignar analista responsable
    db.rpc("activar_sla_tramite", {"p_tramite_id": str(tramite_id)}).execute()

    log.info("tramite_asignado", tramite_id=str(tramite_id), analista=str(body.analista_id), por=str(usuario.id))
    return await obtener_tramite(tramite_id, usuario)


# ---------------------------------------------------------------------------
# GET /tramites/{id}/eventos
# ---------------------------------------------------------------------------

@router.get(
    "/{tramite_id}/eventos",
    response_model=list[EventoResponse],
    summary="Timeline del trÃ¡mite",
    description=(
        "Devuelve el historial de eventos del trÃ¡mite en orden cronolÃ³gico. "
        "Incluye cambios de estado, asignaciones, notas de analistas, acciones de agentes IA y correos. "
        "Usar solo_visibles=false para ver eventos internos del pipeline no visibles en la UI."
    ),
)
async def listar_eventos(
    tramite_id: UUID,
    solo_visibles: bool = Query(default=True, description="True: solo eventos visibles en el timeline de la UI. False: incluye eventos internos del pipeline IA."),
    limit: int = Query(default=100, ge=1, le=500, description="MÃ¡ximo de eventos a devolver."),
    offset: int = Query(default=0, ge=0, description="NÃºmero de eventos a saltar."),
    usuario: UsuarioToken = Depends(get_current_user),
) -> list[EventoResponse]:
    db = get_user_db(usuario.access_token)

    query = db.table("tramite_evento").select(
        "id, tramite_id, tipo_evento, estado_anterior, estado_nuevo, "
        "usuario_id, agente_ia_nombre, descripcion, datos, "
        "visible_en_timeline, created_at, "
        "usuario!tramite_evento_usuario_id_fkey!left(nombre)"
    ).eq("tramite_id", str(tramite_id))

    if solo_visibles:
        query = query.eq("visible_en_timeline", True)

    result = (
        query
        .order("created_at", desc=False)
        .range(offset, offset + limit - 1)
        .execute()
    )

    eventos = []
    for row in result.data:
        usuario_data = row.pop("usuario", None) or {}
        row["usuario_nombre"] = usuario_data.get("nombre")
        eventos.append(EventoResponse.model_validate(row))

    return eventos


# ---------------------------------------------------------------------------
# POST /tramites/{id}/eventos
# ---------------------------------------------------------------------------

@router.post(
    "/{tramite_id}/eventos",
    response_model=EventoResponse,
    status_code=status.HTTP_201_CREATED,
    summary="Agregar nota al trÃ¡mite",
    description=(
        "Agrega una nota interna o solicitud de documentos al timeline del trÃ¡mite. "
        "Tipos permitidos desde la UI: nota_analista, solicitud_documentos. "
        "Los agentes IA usan sus propios triggers y service_role para agregar eventos."
    ),
)
async def agregar_nota(
    tramite_id: UUID,
    body: AgregarNotaBody,
    usuario: UsuarioToken = Depends(get_current_user),
) -> EventoResponse:
    tipos_permitidos = {TipoEventoTramite.nota_analista, TipoEventoTramite.solicitud_documentos}
    if body.tipo_evento not in tipos_permitidos:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            detail={
                "error_code": "TIPO_EVENTO_NO_PERMITIDO",
                "mensaje": f"Tipo de evento no permitido manualmente: '{body.tipo_evento}'.",
                "tipos_permitidos": [t.value for t in tipos_permitidos],
            },
        )

    db = get_user_db(usuario.access_token)
    _get_tramite_o_404(db, tramite_id)

    payload = {
        "tramite_id": str(tramite_id),
        "tipo_evento": body.tipo_evento.value,
        "usuario_id": str(usuario.id),
        "descripcion": body.descripcion,
        "datos": body.datos,
        "visible_en_timeline": body.visible_en_timeline,
    }

    result = (
        db.table("tramite_evento")
        .insert(payload)
        .select(
            "id, tramite_id, tipo_evento, estado_anterior, estado_nuevo, "
            "usuario_id, agente_ia_nombre, descripcion, datos, "
            "visible_en_timeline, created_at"
        )
        .execute()
    )
    if result.data:
        result.data = result.data[0]

    data = result.data
    data["usuario_nombre"] = None

    return EventoResponse.model_validate(data)
