"""
Modelos Pydantic para el módulo de trámites.

Jerarquía:
  tramite         — entidad central con máquina de estados
    tramite_evento  — historia inmutable, append-only
"""

from datetime import datetime
from decimal import Decimal
from enum import StrEnum
from uuid import UUID

from pydantic import BaseModel, Field


# ---------------------------------------------------------------------------
# Enums
# ---------------------------------------------------------------------------

class EstadoTramite(StrEnum):
    recibido = "recibido"
    validando = "validando"
    pendiente_documentos = "pendiente_documentos"
    completo = "completo"
    turnado_gnp = "turnado_gnp"
    en_proceso_gnp = "en_proceso_gnp"
    activado = "activado"
    aprobado = "aprobado"
    rechazado = "rechazado"


class TipoTramite(StrEnum):
    alta = "alta"
    endoso = "endoso"
    renovacion = "renovacion"
    cancelacion = "cancelacion"
    siniestro = "siniestro"
    reactivacion = "reactivacion"
    consulta = "consulta"
    desconocido = "desconocido"


class PrioridadTramite(StrEnum):
    normal = "normal"
    alta = "alta"
    urgente = "urgente"


class CanalOrigenTramite(StrEnum):
    email = "email"
    manual = "manual"
    portal = "portal"


class TipoEventoTramite(StrEnum):
    creacion = "creacion"
    cambio_estado = "cambio_estado"
    asignacion = "asignacion"
    reasignacion = "reasignacion"
    nota_analista = "nota_analista"
    documento_agregado = "documento_agregado"
    correo_recibido = "correo_recibido"
    correo_enviado = "correo_enviado"
    accion_agente_ia = "accion_agente_ia"
    activacion_gnp = "activacion_gnp"
    solicitud_documentos = "solicitud_documentos"
    rechazo_gnp = "rechazo_gnp"
    aprendizaje_rag = "aprendizaje_rag"


# ---------------------------------------------------------------------------
# Máquina de estados — transiciones válidas
# ---------------------------------------------------------------------------

TRANSICIONES_VALIDAS: dict[EstadoTramite, list[EstadoTramite]] = {
    EstadoTramite.recibido: [EstadoTramite.validando],
    EstadoTramite.validando: [
        EstadoTramite.pendiente_documentos,
        EstadoTramite.completo,
    ],
    EstadoTramite.pendiente_documentos: [
        EstadoTramite.completo,
        EstadoTramite.validando,
    ],
    EstadoTramite.completo: [
        EstadoTramite.pendiente_documentos,
        EstadoTramite.turnado_gnp,
    ],
    EstadoTramite.turnado_gnp: [EstadoTramite.en_proceso_gnp],
    EstadoTramite.en_proceso_gnp: [
        EstadoTramite.activado,
        EstadoTramite.rechazado,
    ],
    EstadoTramite.activado: [
        EstadoTramite.en_proceso_gnp,  # endosos con múltiples activaciones
        EstadoTramite.aprobado,
        EstadoTramite.rechazado,
    ],
    EstadoTramite.aprobado: [],   # terminal
    EstadoTramite.rechazado: [],  # terminal
}


# ---------------------------------------------------------------------------
# Tramite — modelos de entrada
# ---------------------------------------------------------------------------

class TramiteCreate(BaseModel):
    tipo_tramite: TipoTramite
    titulo: str = Field(min_length=3, max_length=200)
    descripcion: str | None = Field(default=None, max_length=2000)
    canal_origen: CanalOrigenTramite = CanalOrigenTramite.manual
    prioridad: PrioridadTramite = PrioridadTramite.normal
    ramo: str | None = None          # se hereda del analista si queda NULL
    agente_id: UUID | None = None
    poliza_id: UUID | None = None
    asegurado_id: UUID | None = None
    analista_id: UUID | None = None
    etiquetas: list[str] = Field(default_factory=list)


class TramiteUpdate(BaseModel):
    """Campos que un analista o director puede actualizar directamente."""

    titulo: str | None = Field(default=None, min_length=3, max_length=200)
    descripcion: str | None = Field(default=None, max_length=2000)
    prioridad: PrioridadTramite | None = None
    agente_id: UUID | None = None
    poliza_id: UUID | None = None
    asegurado_id: UUID | None = None
    folio_ot: str | None = Field(default=None, max_length=30)
    requiere_atencion: bool | None = None
    etiquetas: list[str] | None = None
    resumen_ia: str | None = None


class CambiarEstadoBody(BaseModel):
    estado_nuevo: EstadoTramite = Field(
        description="Estado destino. Debe ser una transición válida desde el estado actual. "
                    "Consultar el campo 'transiciones_disponibles' en GET /tramites/{id}."
    )
    motivo_rechazo_gnp: str | None = Field(
        default=None,
        max_length=1000,
        description="Obligatorio cuando estado_nuevo='rechazado'. Texto del motivo de rechazo de GNP.",
    )
    motivo: str | None = Field(
        default=None,
        max_length=500,
        description="Obligatorio cuando estado_nuevo='pendiente_documentos'. Describe qué documentos faltan.",
    )
    folio_ot: str | None = Field(
        default=None,
        max_length=30,
        description="Número de OT asignado por GNP. Registrar al turnar (estado='turnado_gnp').",
    )


class AsignarAnalistaBody(BaseModel):
    analista_id: UUID


class AgregarNotaBody(BaseModel):
    """Nota interna que agrega un analista, gerente o director al timeline."""

    descripcion: str = Field(min_length=2, max_length=2000)
    tipo_evento: TipoEventoTramite = TipoEventoTramite.nota_analista
    visible_en_timeline: bool = True
    datos: dict = Field(default_factory=dict)


# ---------------------------------------------------------------------------
# Tramite — modelos de respuesta
# ---------------------------------------------------------------------------

class TramiteListItem(BaseModel):
    """Vista compacta para dashboards y listados."""

    id: UUID
    folio: str
    folio_ot: str | None
    tipo_tramite: TipoTramite
    estado: EstadoTramite
    prioridad: PrioridadTramite
    ramo: str | None
    titulo: str
    requiere_atencion: bool
    analista_id: UUID | None
    analista_nombre: str | None = None
    agente_id: UUID | None
    agente_nombre: str | None = None
    agente_cua: str | None = None
    fecha_recepcion: datetime
    fecha_limite_sla: datetime | None
    ultima_actividad: datetime
    etiquetas: list[str]

    model_config = {"from_attributes": True}


class TramiteResponse(BaseModel):
    """Detalle completo del trámite."""

    id: UUID
    folio: str
    folio_ot: str | None
    tipo_tramite: TipoTramite
    estado: EstadoTramite
    prioridad: PrioridadTramite
    canal_origen: CanalOrigenTramite
    ramo: str | None
    titulo: str
    descripcion: str | None
    datos_tramite: dict
    resumen_ia: str | None
    etiquetas: list[str]
    requiere_atencion: bool
    score_complejidad: Decimal | None

    # Relaciones
    poliza_id: UUID | None
    poliza_numero: str | None = None
    asegurado_id: UUID | None
    asegurado_nombre: str | None = None
    agente_id: UUID | None
    agente_nombre: str | None = None
    agente_cua: str | None = None
    asistente_id: UUID | None
    analista_id: UUID | None
    analista_nombre: str | None = None
    gerente_id: UUID | None

    # Pipeline IA
    paso_pipeline_actual: str | None
    paso_pipeline_inicio: datetime | None

    # Seguimiento GNP
    fecha_recepcion: datetime
    fecha_limite_sla: datetime | None
    ot_fecha_envio: str | None
    ot_fecha_respuesta: str | None
    motivo_rechazo_gnp: str | None
    ultima_actividad: datetime

    activo: bool
    created_at: datetime
    updated_at: datetime

    # Calculado en el router — no viene de la DB directamente
    transiciones_disponibles: list[str] = Field(
        default_factory=list,
        description="Estados a los que puede transicionar este trámite desde su estado actual. "
                    "Vacío si está en un estado terminal (aprobado, rechazado)."
    )

    model_config = {"from_attributes": True}


# ---------------------------------------------------------------------------
# Tramite Evento — modelos
# ---------------------------------------------------------------------------

class EventoResponse(BaseModel):
    """Un evento en el timeline del trámite."""

    id: UUID
    tramite_id: UUID
    tipo_evento: TipoEventoTramite
    estado_anterior: EstadoTramite | None
    estado_nuevo: EstadoTramite | None
    usuario_id: UUID | None
    usuario_nombre: str | None = None
    agente_ia_nombre: str | None
    descripcion: str
    datos: dict
    visible_en_timeline: bool
    created_at: datetime

    model_config = {"from_attributes": True}
