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
    en_revision = "en_revision"
    pendiente_documentos_agente = "pendiente_documentos_agente"
    turnado_a_gnp = "turnado_a_gnp"
    activado_gnp = "activado_gnp"
    complemento_en_revision = "complemento_en_revision"
    escalado = "escalado"
    completado = "completado"
    rechazado_gnp = "rechazado_gnp"
    cancelado = "cancelado"


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
    EstadoTramite.recibido: [
        EstadoTramite.en_revision,
    ],
    EstadoTramite.en_revision: [
        EstadoTramite.pendiente_documentos_agente,
        EstadoTramite.turnado_a_gnp,
        EstadoTramite.escalado,
    ],
    EstadoTramite.pendiente_documentos_agente: [
        EstadoTramite.en_revision,
        EstadoTramite.escalado,
        EstadoTramite.cancelado,
    ],
    EstadoTramite.turnado_a_gnp: [
        EstadoTramite.activado_gnp,
        EstadoTramite.completado,
        EstadoTramite.rechazado_gnp,
    ],
    EstadoTramite.activado_gnp: [
        EstadoTramite.complemento_en_revision,
        EstadoTramite.rechazado_gnp,
        EstadoTramite.escalado,
        EstadoTramite.cancelado,
    ],
    EstadoTramite.complemento_en_revision: [
        EstadoTramite.turnado_a_gnp,
        EstadoTramite.escalado,
        EstadoTramite.cancelado,
    ],
    EstadoTramite.escalado: [
        EstadoTramite.en_revision,
        EstadoTramite.pendiente_documentos_agente,
        EstadoTramite.activado_gnp,
        EstadoTramite.complemento_en_revision,
        EstadoTramite.cancelado,
    ],
    EstadoTramite.completado: [],    # terminal
    EstadoTramite.rechazado_gnp: [], # terminal
    EstadoTramite.cancelado: [],     # terminal
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
        description="Obligatorio cuando estado_nuevo='rechazado_gnp'. Texto del motivo de rechazo de GNP.",
    )
    motivo: str | None = Field(
        default=None,
        max_length=500,
        description="Obligatorio cuando estado_nuevo='pendiente_documentos_agente'. Describe qué documentos faltan.",
    )
    folio_ot: str | None = Field(
        default=None,
        max_length=30,
        description="Número de OT asignado por GNP. Registrar al turnar (estado='turnado_a_gnp').",
    )


class ReasignacionMasivaBody(BaseModel):
    """Reasigna todos los trámites activos de un analista a otro en una sola operación."""

    analista_origen_id: UUID = Field(
        description="Analista cuyos trámites se van a reasignar (p. ej., el que está de vacaciones)."
    )
    analista_destino_id: UUID = Field(
        description="Analista que recibirá los trámites."
    )
    motivo: str | None = Field(
        default=None,
        max_length=500,
        description="Motivo de la reasignación masiva. Se registra en el evento de cada trámite.",
    )
    solo_estados: list[str] | None = Field(
        default=None,
        description=(
            "Si se indica, solo se reasignan trámites en esos estados. "
            "Por defecto se reasignan todos los estados no terminales."
        ),
    )


class AsignarAnalistaBody(BaseModel):
    analista_id: UUID
    motivo: str | None = Field(
        default=None,
        max_length=500,
        description=(
            "Motivo de la reasignación. Opcional en la primera asignación, "
            "recomendado en reasignaciones. Se guarda en el evento del historial. "
            "Ejemplos: 'Vacaciones del analista', 'Exceso de carga de trabajo'."
        ),
    )


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

    # Correo que originó el trámite (primer correo vinculado con es_origen=true)
    correo_origen_email: str | None = None
    correo_origen_nombre: str | None = None

    activo: bool
    created_at: datetime
    updated_at: datetime

    # Calculado en el router — no viene de la DB directamente
    transiciones_disponibles: list[str] = Field(
        default_factory=list,
        description="Estados a los que puede transicionar este trámite desde su estado actual. "
                    "Vacío si está en un estado terminal (completado, rechazado_gnp, cancelado)."
    )

    model_config = {"from_attributes": True}


# ---------------------------------------------------------------------------
# Tramite Evento — modelos
# ---------------------------------------------------------------------------

class ContactoTramiteResponse(BaseModel):
    """Persona involucrada en el trámite (agente, analista, gerente, asistente)."""

    id: str
    nombre: str
    email: str | None = None
    telefono: str | None = None
    rol: str  # agente | analista | gerente | asistente
    cua: str | None = None

    model_config = {"from_attributes": True}


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
