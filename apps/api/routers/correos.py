"""
Router de correos, adjuntos y documentos.

Correos:
GET    /correos                                   â€” lista con filtros
GET    /correos/{id}                              â€” detalle con adjuntos
PATCH  /correos/{id}                              â€” editar borrador saliente
POST   /correos/{id}/aprobar                      â€” aprobar para envÃ­o (gerentes/directores)

Correos de un trÃ¡mite:
GET    /tramites/{id}/correos                     â€” correos vinculados al trÃ¡mite
POST   /tramites/{id}/correos/{correo_id}         â€” vincular correo a trÃ¡mite
DELETE /tramites/{id}/correos/{correo_id}         â€” desvincular (solo directores)

Adjuntos:
GET    /adjuntos/{id}                             â€” detalle del adjunto (sin campo password)

Documentos:
GET    /tramites/{id}/documentos                  â€” documentos del trÃ¡mite
GET    /documentos/{id}                           â€” detalle con texto_ocr y datos_extraidos
PATCH  /documentos/{id}                           â€” actualizar validaciÃ³n (override Agente 5)
"""

from uuid import UUID

import structlog
from fastapi import APIRouter, Body, Depends, HTTPException, Query, status

from core.auth import get_current_user, require_roles
from core.database import get_user_db
from models.correo import (
    AdjuntoResponse,
    CorreoListItem,
    CorreoResponse,
    CorreoTramiteItem,
    CorreoTramiteVinculo,
    CorreoUpdate,
    DocumentoListItem,
    DocumentoResponse,
    DocumentoValidacionUpdate,
    EstadoCorreo,
    TipoCorreo,
    VincularCorreoBody,
)
from models.pagination import PaginatedResponse
from models.usuario import RolUsuario, UsuarioToken

log = structlog.get_logger(__name__)
router = APIRouter(tags=["correos"])

_SOLO_DIRECTORES = [
    Depends(require_roles(RolUsuario.director_general, RolUsuario.director_ops))
]

# ---------------------------------------------------------------------------
# Constantes de SELECT para evitar repeticiÃ³n
# ---------------------------------------------------------------------------

_SEL_CORREO_LIST = (
    "id, message_id, thread_id, tipo, estado, de_email, de_nombre, "
    "para_emails, asunto, fecha_correo, fecha_envio, analista_id, "
    "created_at, updated_at, "
    "usuario!correo_analista_id_fkey!left(nombre)"
)

_SEL_CORREO_DETAIL = (
    "*, "
    "usuario!correo_analista_id_fkey!left(nombre), "
    "adjunto(id, correo_id, adjunto_padre_id, nombre_archivo, tipo_mime, "
    "tamanio_bytes, storage_path, password_eliminado, estado, "
    "motivo_error, created_at, updated_at)"
)

_SEL_DOCUMENTO_LIST = (
    "id, adjunto_id, tramite_id, tipo_documento, confianza_clasificacion, "
    "confianza_ocr, modelo_ocr, intentos_ocr, "
    "vigente_hasta, estado_validacion, motivo_invalidez, "
    "created_at, updated_at, "
    "adjunto!left(nombre_archivo)"
)

_SEL_DOCUMENTO_DETAIL = "*, adjunto!left(nombre_archivo)"


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _armar_correo_list(row: dict) -> CorreoListItem:
    analista = row.pop("usuario", None) or {}
    row["analista_nombre"] = analista.get("nombre")
    return CorreoListItem.model_validate(row)


def _armar_correo_response(data: dict) -> CorreoResponse:
    analista = data.pop("usuario", None) or {}
    data["analista_nombre"] = analista.get("nombre")
    data["adjuntos"] = data.pop("adjunto", []) or []
    return CorreoResponse.model_validate(data)


def _armar_documento_list(row: dict) -> DocumentoListItem:
    adj = row.pop("adjunto", None) or {}
    row["adjunto_nombre"] = adj.get("nombre_archivo")
    return DocumentoListItem.model_validate(row)


def _armar_documento_response(data: dict) -> DocumentoResponse:
    adj = data.pop("adjunto", None) or {}
    data["adjunto_nombre"] = adj.get("nombre_archivo")
    return DocumentoResponse.model_validate(data)


def _get_correo_o_404(db, correo_id: UUID) -> dict:
    result = (
        db.table("correo")
        .select("id, tipo, estado, analista_id")
        .eq("id", str(correo_id))
        .maybe_single()
        .execute()
    )
    if not result:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Correo no encontrado.")
    return result.data


# ===========================================================================
# CORREOS
# ===========================================================================

@router.get(
    "/correos",
    response_model=PaginatedResponse[CorreoListItem],
    summary="Listar correos",
    description=(
        "Devuelve correos entrantes y salientes accesibles segÃºn el rol del usuario. "
        "Directores ven todos; gerentes y analistas ven correos de sus trÃ¡mites. "
        "Filtrable por tipo (entrante/saliente), estado, analista y hilo de Gmail. "
        "Respuesta paginada con total y has_more."
    ),
)
async def listar_correos(
    tipo: TipoCorreo | None = Query(default=None, description="entrante o saliente."),
    estado: EstadoCorreo | None = Query(default=None, description="Estado del correo en su ciclo de vida."),
    analista_id: UUID | None = Query(default=None, description="UUID del analista responsable."),
    thread_id: str | None = Query(default=None, description="ID del hilo de Gmail para agrupar conversaciones."),
    q: str | None = Query(default=None, description="BÃºsqueda en asunto y direcciÃ³n del remitente."),
    limit: int = Query(default=50, ge=1, le=200, description="MÃ¡ximo de registros por pÃ¡gina."),
    offset: int = Query(default=0, ge=0, description="NÃºmero de registros a saltar."),
    usuario: UsuarioToken = Depends(get_current_user),
) -> PaginatedResponse[CorreoListItem]:
    db = get_user_db(usuario.access_token)

    def _apply_filters(q_builder):
        if tipo:
            q_builder = q_builder.eq("tipo", tipo.value)
        if estado:
            q_builder = q_builder.eq("estado", estado.value)
        if analista_id:
            q_builder = q_builder.eq("analista_id", str(analista_id))
        if thread_id:
            q_builder = q_builder.eq("thread_id", thread_id)
        if q:
            q_builder = q_builder.or_(f"asunto.ilike.%{q}%,de_email.ilike.%{q}%")
        return q_builder

    count_result = _apply_filters(db.table("correo").select("id", count="exact")).execute()
    total = count_result.count or 0

    result = (
        _apply_filters(db.table("correo").select(_SEL_CORREO_LIST))
        .order("fecha_correo", desc=True)
        .range(offset, offset + limit - 1)
        .execute()
    )
    items = [_armar_correo_list(row) for row in result.data]
    return PaginatedResponse.build(items=items, total=total, offset=offset, limit=limit)


@router.get("/correos/{correo_id}", response_model=CorreoResponse)
async def obtener_correo(
    correo_id: UUID,
    usuario: UsuarioToken = Depends(get_current_user),
) -> CorreoResponse:
    db = get_user_db(usuario.access_token)
    result = (
        db.table("correo")
        .select(_SEL_CORREO_DETAIL)
        .eq("id", str(correo_id))
        .maybe_single()
        .execute()
    )
    if not result:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Correo no encontrado.")
    return _armar_correo_response(result.data)


@router.patch("/correos/{correo_id}", response_model=CorreoResponse)
async def actualizar_correo(
    correo_id: UUID,
    body: CorreoUpdate,
    usuario: UsuarioToken = Depends(get_current_user),
) -> CorreoResponse:
    cambios = body.model_dump(exclude_none=True)
    if not cambios:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            detail="No se enviaron campos.",
        )

    db = get_user_db(usuario.access_token)
    correo = _get_correo_o_404(db, correo_id)

    if correo["tipo"] != TipoCorreo.saliente:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            detail="Solo se pueden editar correos salientes.",
        )

    estados_editables = {EstadoCorreo.borrador.value, EstadoCorreo.en_revision.value}
    if correo["estado"] not in estados_editables:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            detail=f"No se puede editar un correo en estado '{correo['estado']}'.",
        )

    if usuario.rol == RolUsuario.analista and str(correo.get("analista_id")) != str(usuario.id):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Solo puedes editar tus propios borradores.",
        )

    db.table("correo").update(cambios).eq("id", str(correo_id)).execute()
    return await obtener_correo(correo_id, usuario)


@router.post("/correos/{correo_id}/aprobar", response_model=CorreoResponse)
async def aprobar_correo(
    correo_id: UUID,
    usuario: UsuarioToken = Depends(
        require_roles(RolUsuario.director_general, RolUsuario.director_ops, RolUsuario.gerente)
    ),
) -> CorreoResponse:
    """Aprueba un borrador saliente para envÃ­o. Solo gerentes y directores."""
    db = get_user_db(usuario.access_token)
    correo = _get_correo_o_404(db, correo_id)

    if correo["tipo"] != TipoCorreo.saliente:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            detail="Solo se pueden aprobar correos salientes.",
        )

    estados_aprobables = {EstadoCorreo.borrador.value, EstadoCorreo.en_revision.value}
    if correo["estado"] not in estados_aprobables:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            detail=f"El correo estÃ¡ en estado '{correo['estado']}' y no se puede aprobar.",
        )

    db.table("correo").update({"estado": EstadoCorreo.aprobado.value}).eq("id", str(correo_id)).execute()
    log.info("correo_aprobado", correo_id=str(correo_id), por=str(usuario.id))
    return await obtener_correo(correo_id, usuario)


# ===========================================================================
# CORREOS DE UN TRÃMITE
# ===========================================================================

@router.get("/tramites/{tramite_id}/correos", response_model=list[CorreoTramiteItem])
async def listar_correos_tramite(
    tramite_id: UUID,
    usuario: UsuarioToken = Depends(get_current_user),
) -> list[CorreoTramiteItem]:
    db = get_user_db(usuario.access_token)
    result = (
        db.table("correo_tramite")
        .select(
            "es_origen, "
            "correo("
            "id, message_id, thread_id, tipo, estado, de_email, de_nombre, "
            "para_emails, asunto, fecha_correo, fecha_envio, analista_id, "
            "created_at, updated_at, "
            "usuario!correo_analista_id_fkey!left(nombre)"
            ")"
        )
        .eq("tramite_id", str(tramite_id))
        .order("created_at")
        .execute()
    )

    items = []
    for row in result.data:
        correo_data = dict(row.get("correo") or {})
        analista = correo_data.pop("usuario", None) or {}
        correo_data["analista_nombre"] = analista.get("nombre")
        correo_data["es_origen"] = row.get("es_origen", False)
        items.append(CorreoTramiteItem.model_validate(correo_data))
    return items


@router.post(
    "/tramites/{tramite_id}/correos/{correo_id}",
    response_model=CorreoTramiteVinculo,
    status_code=status.HTTP_201_CREATED,
)
async def vincular_correo_tramite(
    tramite_id: UUID,
    correo_id: UUID,
    body: VincularCorreoBody = Body(default_factory=VincularCorreoBody),
    usuario: UsuarioToken = Depends(get_current_user),
) -> CorreoTramiteVinculo:
    db = get_user_db(usuario.access_token)

    try:
        result = (
            db.table("correo_tramite")
            .insert({
                "correo_id": str(correo_id),
                "tramite_id": str(tramite_id),
                "es_origen": body.es_origen,
            })
            .select("correo_id, tramite_id, es_origen, created_at")
            .execute()
        )
        if result.data:
            result.data = result.data[0]
    except Exception as exc:
        msg = str(exc)
        if "correo_tramite_pkey" in msg or "duplicate" in msg.lower():
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="Este correo ya estÃ¡ vinculado a este trÃ¡mite.",
            )
        raise

    return CorreoTramiteVinculo.model_validate(result.data)


@router.delete(
    "/tramites/{tramite_id}/correos/{correo_id}",
    status_code=status.HTTP_204_NO_CONTENT,
    dependencies=_SOLO_DIRECTORES,
    summary="Desvincular correo de trÃ¡mite",
    description="Elimina la relaciÃ³n entre un correo y un trÃ¡mite. Solo directores. AcciÃ³n irreversible desde la API (el correo no se elimina).",
)
async def desvincular_correo_tramite(
    tramite_id: UUID,
    correo_id: UUID,
) -> None:
    # _SOLO_DIRECTORES ya valida auth+rol â€” no se necesita get_current_user aquÃ­
    from core.database import get_admin_db
    db = get_admin_db()
    db.table("correo_tramite").delete().eq("correo_id", str(correo_id)).eq("tramite_id", str(tramite_id)).execute()
    log.info("correo_desvinculado", correo_id=str(correo_id), tramite_id=str(tramite_id))


# ===========================================================================
# ADJUNTOS
# ===========================================================================

@router.get("/adjuntos/{adjunto_id}", response_model=AdjuntoResponse)
async def obtener_adjunto(
    adjunto_id: UUID,
    usuario: UsuarioToken = Depends(get_current_user),
) -> AdjuntoResponse:
    db = get_user_db(usuario.access_token)
    result = (
        db.table("adjunto")
        .select(
            "id, correo_id, adjunto_padre_id, nombre_archivo, tipo_mime, "
            "tamanio_bytes, storage_path, password_eliminado, estado, "
            "motivo_error, created_at, updated_at"
        )
        .eq("id", str(adjunto_id))
        .maybe_single()
        .execute()
    )
    if not result:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Adjunto no encontrado.")
    return AdjuntoResponse.model_validate(result.data)


# ===========================================================================
# DOCUMENTOS
# ===========================================================================

@router.get("/tramites/{tramite_id}/documentos", response_model=list[DocumentoListItem])
async def listar_documentos_tramite(
    tramite_id: UUID,
    tipo_documento: str | None = Query(default=None),
    estado_validacion: str | None = Query(default=None),
    usuario: UsuarioToken = Depends(get_current_user),
) -> list[DocumentoListItem]:
    db = get_user_db(usuario.access_token)
    query = db.table("documento").select(_SEL_DOCUMENTO_LIST).eq("tramite_id", str(tramite_id))

    if tipo_documento:
        query = query.eq("tipo_documento", tipo_documento)
    if estado_validacion:
        query = query.eq("estado_validacion", estado_validacion)

    result = query.order("created_at").execute()
    return [_armar_documento_list(row) for row in result.data]


@router.get("/documentos/{doc_id}", response_model=DocumentoResponse)
async def obtener_documento(
    doc_id: UUID,
    usuario: UsuarioToken = Depends(get_current_user),
) -> DocumentoResponse:
    db = get_user_db(usuario.access_token)
    result = (
        db.table("documento")
        .select(_SEL_DOCUMENTO_DETAIL)
        .eq("id", str(doc_id))
        .maybe_single()
        .execute()
    )
    if not result:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Documento no encontrado.")
    return _armar_documento_response(result.data)


@router.patch("/documentos/{doc_id}", response_model=DocumentoResponse)
async def actualizar_documento(
    doc_id: UUID,
    body: DocumentoValidacionUpdate,
    usuario: UsuarioToken = Depends(get_current_user),
) -> DocumentoResponse:
    """Override manual de la validaciÃ³n del Agente 5 â€” analistas y superiores."""
    cambios = body.model_dump(exclude_none=True)
    if not cambios:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            detail="No se enviaron campos.",
        )

    if "tipo_documento" in cambios:
        cambios["tipo_documento"] = cambios["tipo_documento"].value
    if "estado_validacion" in cambios:
        cambios["estado_validacion"] = cambios["estado_validacion"].value

    db = get_user_db(usuario.access_token)
    result = (
        db.table("documento")
        .update(cambios)
        .eq("id", str(doc_id))
        .select(_SEL_DOCUMENTO_DETAIL)
        .execute()
    )
    if result.data:
        result.data = result.data[0]
    if not result.data:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Documento no encontrado.")
    log.info("documento_validacion_actualizado", doc_id=str(doc_id), cambios=cambios, por=str(usuario.id))
    return _armar_documento_response(result.data)
