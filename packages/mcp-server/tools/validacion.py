"""
Herramientas para el Agente 5 — Validación de documentos.

El Agente 5 es el más crítico del pipeline. Consulta los tres RAGs,
valida documentos contra requisitos GNP, registra aprendizajes de rechazo
y cambia el estado del trámite.
"""

from __future__ import annotations

from typing import Any

from core.db import get_db
from core.mcp_instance import mcp


# =============================================================================
# BÚSQUEDA EN RAG — Corazón de la validación
# =============================================================================

@mcp.tool()
def buscar_conocimiento_gnp(
    embedding: list[float],
    ramo: str | None = None,
    tipo_tramite: str | None = None,
    tipo_documento: str | None = None,
    limite: int = 5,
    umbral_similitud: float = 0.65,
) -> dict[str, Any]:
    """Busca requisitos y criterios en la base de conocimiento de GNP.

    El Agente 5 llama esto para saber qué documentos son requeridos y
    cuáles son los criterios de validación para cada tipo de trámite/documento.
    Pre-filtrar siempre por ramo y tipo_tramite para mejor precisión y menor costo.

    Args:
        embedding: Vector de 1536 dimensiones generado con text-embedding-3-small
            sobre el texto del documento o la consulta de validación.
        ramo: vida | gmm | autos | pyme. Filtrar siempre que sea posible.
        tipo_tramite: alta | endoso | renovacion | etc. (opcional).
        tipo_documento: ine | solicitud_alta | carta_medica | etc. (opcional).
        limite: Máximo de chunks a retornar (default 5, máx recomendado 10).
        umbral_similitud: Similitud coseno mínima (default 0.65).

    Returns: {"chunks": [{"contenido": "...", "similitud": 0.87,
              "tipo_fuente": "requisitos", "titulo_fuente": "...", ...}]}
    """
    db = get_db()
    params: dict[str, Any] = {
        "p_embedding": embedding,
        "p_limite": limite,
        "p_umbral_similitud": umbral_similitud,
    }
    if ramo:
        params["p_ramo"] = ramo
    if tipo_tramite:
        params["p_tipo_tramite"] = tipo_tramite
    if tipo_documento:
        params["p_tipo_documento"] = tipo_documento

    result = db.rpc("buscar_rag_gnp", params).execute()
    return {"chunks": result.data or []}


@mcp.tool()
def buscar_historial_poliza(
    embedding: list[float],
    poliza_id: str | None = None,
    agente_cua: str | None = None,
    ramo: str | None = None,
    tipo_chunk: str | None = None,
    limite: int = 5,
    umbral: float = 0.60,
) -> dict[str, Any]:
    """Busca en el historial de pólizas procesadas anteriormente.

    El Agente 5 usa esto para entender el historial de una póliza antes
    de validar un nuevo trámite. Permite detectar patrones repetidos.

    Args:
        embedding: Vector de búsqueda (1536 dims).
        poliza_id: UUID de la póliza (filtrar por póliza específica).
        agente_cua: CUA del agente (filtrar por historial del agente).
        ramo: vida | gmm | autos | pyme (opcional).
        tipo_chunk: validacion_exitosa | activacion_gnp | rechazo_gnp |
            aprobacion_final | endoso_procesado | patron_detectado (opcional).
        limite: Máximo de chunks (default 5).
        umbral: Similitud mínima (default 0.60 — historial puede ser menos preciso).

    Returns: {"chunks": [...]}
    """
    db = get_db()
    params: dict[str, Any] = {
        "p_embedding": embedding,
        "p_limite": limite,
        "p_umbral": umbral,
    }
    if poliza_id:
        params["p_poliza_id"] = poliza_id
    if agente_cua:
        params["p_agente_cua"] = agente_cua
    if ramo:
        params["p_ramo"] = ramo
    if tipo_chunk:
        params["p_tipo_chunk"] = tipo_chunk

    result = db.rpc("buscar_rag_poliza", params).execute()
    return {"chunks": result.data or []}


@mcp.tool()
def buscar_rechazos_similares(
    embedding: list[float],
    ramo: str | None = None,
    tipo_tramite: str | None = None,
    tipo_documento: str | None = None,
    solo_resueltos: bool = False,
    limite: int = 5,
    umbral: float = 0.65,
) -> dict[str, Any]:
    """Busca rechazos históricos similares para anticipar problemas.

    El Agente 5 llama esto PRIMERO antes de validar, para saber si hay
    rechazos previos similares que podrían repetirse.
    Solo retorna aprendizajes validados por analistas (descarta ruido).

    Args:
        embedding: Vector de búsqueda sobre el documento o trámite actual.
        ramo: Filtrar por ramo.
        tipo_tramite: Filtrar por tipo de trámite.
        tipo_documento: Filtrar por tipo de documento que causó el rechazo.
        solo_resueltos: True para ver solo rechazos que se corrigieron con éxito.
        limite: Máximo de resultados (default 5).
        umbral: Similitud mínima (default 0.65).

    Returns: {"aprendizajes": [{"contenido": "...", "motivo_rechazo": "...",
              "correccion_aplicada": "...", "resuelto": true, "similitud": 0.78}]}
    """
    db = get_db()
    params: dict[str, Any] = {
        "p_embedding": embedding,
        "p_solo_resueltos": solo_resueltos,
        "p_limite": limite,
        "p_umbral": umbral,
    }
    if ramo:
        params["p_ramo"] = ramo
    if tipo_tramite:
        params["p_tipo_tramite"] = tipo_tramite
    if tipo_documento:
        params["p_tipo_documento"] = tipo_documento

    result = db.rpc("buscar_rag_aprendizaje", params).execute()
    return {"aprendizajes": result.data or []}


# =============================================================================
# ESCRITURA EN RAG — El sistema aprende
# =============================================================================

@mcp.tool()
def agregar_chunk_historial_poliza(
    tramite_id: str,
    contenido: str,
    tipo_chunk: str,
    embedding: list[float],
    ramo: str,
    poliza_id: str | None = None,
    tramite_evento_id: str | None = None,
    agente_cua: str | None = None,
    tipo_tramite: str | None = None,
    version_embedding: str = "text-embedding-3-small",
    num_tokens: int | None = None,
) -> dict[str, Any]:
    """Registra un chunk narrativo en el historial de pólizas.

    El Agente 5 llama esto al completar una validación, activación o cualquier
    evento significativo. Con el tiempo construye un historial rico por póliza.

    Args:
        tramite_id: UUID del trámite que originó este chunk.
        contenido: Narrativa del evento. Debe ser auto-contenida con suficiente
            contexto. Ver el comentario en la migración rag_poliza para el formato.
        tipo_chunk: validacion_exitosa | activacion_gnp | aprobacion_final |
            rechazo_gnp | endoso_procesado | patron_detectado.
        embedding: Vector generado sobre el contenido (1536 dims).
        ramo: vida | gmm | autos | pyme.
        poliza_id: UUID de la póliza (si está en el catálogo).
        tramite_evento_id: UUID del evento específico que originó este chunk.
        agente_cua: CUA del agente (denormalizado para búsqueda sin JOIN).
        tipo_tramite: alta | endoso | etc.
        version_embedding: Modelo usado. Default 'text-embedding-3-small'.
        num_tokens: Tokens del chunk para análisis de costos.

    Returns: {"chunk_id": "<uuid>"}
    """
    db = get_db()
    payload: dict[str, Any] = {
        "tramite_id": tramite_id,
        "contenido": contenido,
        "tipo_chunk": tipo_chunk,
        "embedding": embedding,
        "ramo": ramo,
        "version_embedding": version_embedding,
    }
    if poliza_id:
        payload["poliza_id"] = poliza_id
    if tramite_evento_id:
        payload["tramite_evento_id"] = tramite_evento_id
    if agente_cua:
        payload["agente_cua"] = agente_cua
    if tipo_tramite:
        payload["tipo_tramite"] = tipo_tramite
    if num_tokens:
        payload["num_tokens"] = num_tokens

    result = db.table("rag_poliza").insert(payload).execute()
    if not result.data:
        return {"error": "No se pudo agregar el chunk"}
    return {"chunk_id": result.data[0]["id"]}


@mcp.tool()
def registrar_aprendizaje_rechazo(
    tramite_id: str,
    contenido: str,
    ramo: str,
    motivo_rechazo: str,
    embedding: list[float],
    tipo_tramite: str | None = None,
    tipo_documento: str | None = None,
    documento_id: str | None = None,
    poliza_id: str | None = None,
    codigo_rechazo_gnp: str | None = None,
    correccion_aplicada: str | None = None,
    version_embedding: str = "text-embedding-3-small",
) -> dict[str, Any]:
    """Registra un aprendizaje de rechazo de GNP.

    El Agente 5 llama esto cuando GNP rechaza un trámite.
    Este registro es el diferenciador competitivo del sistema —
    aprende de cada error para evitar repetirlos.
    El aprendizaje queda pendiente de validación por el analista.

    Args:
        tramite_id: UUID del trámite rechazado.
        contenido: Explicación detallada del rechazo, causa y corrección.
            Ver formato en los comentarios de la migración rag_aprendizaje.
        ramo: vida | gmm | autos | pyme.
        motivo_rechazo: Descripción legible del motivo de rechazo de GNP.
        embedding: Vector generado sobre el contenido.
        tipo_tramite: Tipo de trámite rechazado.
        tipo_documento: Tipo de documento que causó el rechazo.
        documento_id: UUID del documento específico que causó el problema.
        poliza_id: UUID de la póliza relacionada.
        codigo_rechazo_gnp: Código oficial de GNP si lo provee.
        correccion_aplicada: Qué se hizo para corregir el problema.
        version_embedding: Modelo de embedding.

    Returns: {"aprendizaje_id": "<uuid>"}
    """
    db = get_db()
    payload: dict[str, Any] = {
        "tramite_id": tramite_id,
        "contenido": contenido,
        "ramo": ramo,
        "motivo_rechazo": motivo_rechazo,
        "embedding": embedding,
        "version_embedding": version_embedding,
        "aprendizaje_validado": False,
        "descartado": False,
        "resuelto": False,
    }
    if tipo_tramite:
        payload["tipo_tramite"] = tipo_tramite
    if tipo_documento:
        payload["tipo_documento"] = tipo_documento
    if documento_id:
        payload["documento_id"] = documento_id
    if poliza_id:
        payload["poliza_id"] = poliza_id
    if codigo_rechazo_gnp:
        payload["codigo_rechazo_gnp"] = codigo_rechazo_gnp
    if correccion_aplicada:
        payload["correccion_aplicada"] = correccion_aplicada

    result = db.table("rag_aprendizaje").insert(payload).execute()
    if not result.data:
        return {"error": "No se pudo registrar el aprendizaje"}
    return {"aprendizaje_id": result.data[0]["id"]}


# =============================================================================
# MÁQUINA DE ESTADOS
# =============================================================================

@mcp.tool()
def cambiar_estado_tramite(
    tramite_id: str,
    estado_nuevo: str,
    descripcion: str = "Cambio de estado vía agente IA",
    agente_ia_nombre: str | None = None,
    usuario_id: str | None = None,
    datos: dict | None = None,
) -> dict[str, Any]:
    """Ejecuta una transición de estado en el trámite con validación de secuencia.

    Llama a la función PostgreSQL cambiar_estado_tramite que:
    1. Valida la transición contra la máquina de estados
    2. Actualiza tramite.estado con SELECT FOR UPDATE (previene condiciones de carrera)
    3. Registra automáticamente el evento en tramite_evento

    Transiciones válidas:
      recibido → validando | rechazado
      validando → pendiente_documentos | completo | rechazado
      pendiente_documentos ↔ validando | completo | rechazado
      completo → turnado_gnp | pendiente_documentos | rechazado
      turnado_gnp → en_proceso_gnp | rechazado
      en_proceso_gnp → activado | rechazado
      activado → aprobado | activado (endosos múltiples) | rechazado
      aprobado, rechazado → [estados finales]

    Args:
        tramite_id: UUID del trámite.
        estado_nuevo: Estado destino. Ver transiciones válidas arriba.
        descripcion: Texto legible del cambio para el historial del analista.
            Ej: 'El Agente 5 validó todos los documentos. Listo para GNP.'
        agente_ia_nombre: Nombre del agente IA que ejecuta el cambio.
            Ej: 'agente_5'. Usar si el actor es un agente IA (mutuamente excluyente con usuario_id).
        usuario_id: UUID del analista si el cambio lo ejecuta un humano.
            Mutuamente excluyente con agente_ia_nombre.
        datos: Datos adicionales para el registro del evento (JSON).
            Ej: {"documentos_validos": 3, "confianza_promedio": 0.91}.

    Returns: {"ok": bool, "estado_anterior": "...", "estado_nuevo": "...",
              "evento_id": "<uuid>", "error_msg": null}
    """
    db = get_db()
    params: dict[str, Any] = {
        "p_tramite_id": tramite_id,
        "p_estado_nuevo": estado_nuevo,
        "p_descripcion": descripcion,
        "p_datos": datos or {},
    }
    if agente_ia_nombre:
        params["p_agente_ia_nombre"] = agente_ia_nombre
    if usuario_id:
        params["p_usuario_id"] = usuario_id

    result = db.rpc("cambiar_estado_tramite", params).execute()
    if not result.data:
        return {"ok": False, "error_msg": "Sin respuesta de la función SQL"}
    return result.data[0]
