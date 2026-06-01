"""
Modelos Pydantic para correos, adjuntos y documentos.
"""

from datetime import date, datetime
from decimal import Decimal
from enum import StrEnum
from uuid import UUID

from pydantic import BaseModel, Field, model_validator


class TipoCorreo(StrEnum):
    entrante = "entrante"
    saliente = "saliente"


class EstadoCorreo(StrEnum):
    # Entrantes
    recibido = "recibido"
    procesando = "procesando"
    procesado = "procesado"
    error_procesamiento = "error_procesamiento"
    # Salientes
    borrador = "borrador"
    en_revision = "en_revision"
    aprobado = "aprobado"
    enviado = "enviado"
    error_envio = "error_envio"


class EstadoAdjunto(StrEnum):
    pendiente = "pendiente"
    procesando = "procesando"
    procesado = "procesado"
    ilegible = "ilegible"
    error = "error"


class TipoDocumento(StrEnum):
    # Identificación personal
    ine = "ine"
    pasaporte = "pasaporte"
    acta_nacimiento = "acta_nacimiento"
    curp = "curp"
    comprobante_domicilio = "comprobante_domicilio"
    # Trámite GNP
    solicitud_alta = "solicitud_alta"
    formulario_gnp = "formulario_gnp"
    carta_medica = "carta_medica"
    dictamen_medico = "dictamen_medico"
    cuestionario_salud = "cuestionario_salud"
    poliza_anterior = "poliza_anterior"
    endoso = "endoso"
    # Autos
    tarjeta_circulacion = "tarjeta_circulacion"
    factura_vehiculo = "factura_vehiculo"
    fotografia_vehiculo = "fotografia_vehiculo"
    # Pyme / persona moral
    acta_constitutiva = "acta_constitutiva"
    poder_notarial = "poder_notarial"
    cedula_fiscal = "cedula_fiscal"
    estado_cuenta = "estado_cuenta"
    # Financiero
    comprobante_pago = "comprobante_pago"
    recibo_prima = "recibo_prima"
    # Catch-all
    otro = "otro"


class EstadoValidacionDocumento(StrEnum):
    pendiente_validacion = "pendiente_validacion"
    valido = "valido"
    invalido = "invalido"
    ilegible = "ilegible"
    vencido = "vencido"
    duplicado = "duplicado"


# ---------------------------------------------------------------------------
# Adjunto — NUNCA exponer el campo 'password'
# ---------------------------------------------------------------------------


class AdjuntoResponse(BaseModel):
    id: UUID
    correo_id: UUID
    adjunto_padre_id: UUID | None
    nombre_archivo: str
    tipo_mime: str | None
    tamanio_bytes: int | None
    storage_path: str | None
    password_eliminado: bool
    estado: EstadoAdjunto
    motivo_error: str | None
    created_at: datetime
    updated_at: datetime

    model_config = {"from_attributes": True}


# ---------------------------------------------------------------------------
# Documento
# ---------------------------------------------------------------------------


class DocumentoListItem(BaseModel):
    """Vista compacta — excluye texto_ocr y datos_extraidos (pueden ser grandes)."""

    id: UUID
    adjunto_id: UUID
    tramite_id: UUID
    adjunto_nombre: str | None = None
    tipo_documento: TipoDocumento
    confianza_clasificacion: Decimal | None
    confianza_ocr: Decimal | None
    modelo_ocr: str | None
    intentos_ocr: int
    vigente_hasta: date | None
    estado_validacion: EstadoValidacionDocumento
    motivo_invalidez: str | None
    created_at: datetime
    updated_at: datetime

    model_config = {"from_attributes": True}


class DocumentoResponse(DocumentoListItem):
    """Detalle completo — incluye texto OCR y datos estructurados extraídos."""

    texto_ocr: str | None
    datos_extraidos: dict

    model_config = {"from_attributes": True}


class DocumentoValidacionUpdate(BaseModel):
    """Corrección manual del Agente 5 por parte del analista."""

    tipo_documento: TipoDocumento | None = None
    estado_validacion: EstadoValidacionDocumento | None = None
    motivo_invalidez: str | None = Field(default=None, max_length=1000)

    @model_validator(mode="after")
    def validar_motivo(self) -> "DocumentoValidacionUpdate":
        estados_con_motivo = {
            EstadoValidacionDocumento.invalido,
            EstadoValidacionDocumento.ilegible,
            EstadoValidacionDocumento.vencido,
            EstadoValidacionDocumento.duplicado,
        }
        if self.estado_validacion in estados_con_motivo and not self.motivo_invalidez:
            raise ValueError(
                f"motivo_invalidez es obligatorio cuando estado_validacion es '{self.estado_validacion}'."
            )
        return self


# ---------------------------------------------------------------------------
# Correo
# ---------------------------------------------------------------------------


class CorreoListItem(BaseModel):
    id: UUID
    message_id: str | None
    thread_id: str | None
    in_reply_to: str | None = Field(
        default=None,
        description=(
            "Valor del header RFC 2822 In-Reply-To. "
            "Para correos entrantes: extraído del email. "
            "Para salientes: message_id del correo al que se responde."
        ),
    )
    tipo: TipoCorreo
    estado: EstadoCorreo
    de_email: str
    de_nombre: str | None
    para_emails: list[str]
    asunto: str
    fecha_correo: datetime
    fecha_envio: datetime | None
    analista_id: UUID | None
    analista_nombre: str | None = None
    created_at: datetime
    updated_at: datetime

    model_config = {"from_attributes": True}


class CorreoTramiteItem(CorreoListItem):
    """Correo en el contexto de un trámite — agrega el flag es_origen."""

    es_origen: bool = False

    model_config = {"from_attributes": True}


class CorreoThreadItem(CorreoListItem):
    """
    Correo en el hilo del trámite con árbol de respuestas.
    Devuelto por GET /tramites/{id}/correos/thread.
    """

    tramite_id: UUID
    es_origen: bool = False
    correo_padre_id: UUID | None = Field(
        default=None,
        description=(
            "UUID del correo padre en la DB. "
            "NULL = raíz del hilo o padre no encontrado en la DB. "
            "Usar para construir el árbol localmente en la UI."
        ),
    )
    cc_emails: list[str] = []

    model_config = {"from_attributes": True}


class CorreoResponse(CorreoListItem):
    """Detalle completo con cuerpo, adjuntos y referencia al archivo raw en Storage."""

    cc_emails: list[str]
    cuerpo_html: str | None
    cuerpo_texto: str | None
    datos_agente2: dict | None
    eml_storage_path: str | None = Field(
        default=None,
        description=(
            "Ruta del archivo .eml completo en Supabase Storage. "
            "NULL hasta que el Agente 1 finaliza la subida. "
            "Usar junto con eml_storage_bucket para construir la referencia completa."
        ),
    )
    eml_storage_bucket: str | None = Field(
        default=None,
        description="Bucket de Supabase Storage donde vive el .eml ('correos-inbox' o 'correos-archivados').",
    )
    adjuntos: list[AdjuntoResponse] = []

    model_config = {"from_attributes": True}


class CorreoUpdate(BaseModel):
    """Edición de borradores salientes."""

    asunto: str | None = Field(default=None, min_length=1, max_length=500)
    cuerpo_html: str | None = None
    cuerpo_texto: str | None = None


class CorreoTramiteVinculo(BaseModel):
    correo_id: UUID
    tramite_id: UUID
    es_origen: bool
    created_at: datetime

    model_config = {"from_attributes": True}


class VincularCorreoBody(BaseModel):
    es_origen: bool = False
