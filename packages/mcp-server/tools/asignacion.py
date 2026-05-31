"""
Herramientas para el Agente 4 — Asignación de trámites.

Cascada CUA:
  1. Buscar agente por CUA exacto
  2. Si falla → buscar por nombre fuzzy (buscar_agente_fuzzy)
  3. Si falla → tramite.agente_id = NULL, escalada a analista
  Luego: obtener_asignacion_agente → asignar_analista_tramite
"""

from __future__ import annotations

from typing import Any

from core.db import get_db
from core.mcp_instance import mcp


@mcp.tool()
def buscar_agente_por_cua(cua: str) -> dict[str, Any]:
    """Busca un agente de seguros por su Clave Única de Agente (CUA) exacta.

    Primer paso de la cascada CUA del Agente 4.
    El CUA es el identificador principal que GNP asigna a cada agente.

    Args:
        cua: Clave Única de Agente. Ej: '1234567'.

    Returns: {"agente": {...}} o {"agente": null, "encontrado": false}
    """
    db = get_db()
    result = db.table("agente").select(
        "id, nombre, cua, email, telefono, ramo, activo"
    ).eq("cua", cua).eq("activo", True).maybe_single().execute()

    if not result.data:
        return {"agente": None, "encontrado": False}
    return {"agente": result.data, "encontrado": True}


@mcp.tool()
def buscar_agente_fuzzy(
    nombre: str,
    ramo: str | None = None,
    limite: int = 5,
    umbral: float = 0.30,
) -> dict[str, Any]:
    """Busca agentes por similitud de nombre usando pg_trgm.

    Segundo paso de la cascada CUA cuando el CUA exacto no se encontró.
    El umbral 0.30 corresponde a ~FUZZY_MATCH_NOMBRE configurado en el sistema.
    Usar obtener_configuracion_agentes() para obtener el umbral real.

    Args:
        nombre: Nombre aproximado del agente extraído del correo.
        ramo: Filtrar por ramo (vida | gmm | autos | pyme). Mejora precisión.
        limite: Máximo de candidatos a retornar (default 5).
        umbral: Similitud mínima pg_trgm (0.0-1.0). Default 0.30.

    Returns: {"agentes": [{"id":..., "nombre":..., "cua":..., "similitud":...}]}
    """
    db = get_db()
    params: dict[str, Any] = {
        "p_nombre": nombre,
        "p_limite": limite,
        "p_umbral_trgm": umbral,
    }
    if ramo:
        params["p_ramo"] = ramo

    result = db.rpc("buscar_agente_fuzzy", params).execute()
    return {"agentes": result.data or []}


@mcp.tool()
def obtener_asignacion_agente(
    agente_id: str,
    ramo: str,
) -> dict[str, Any]:
    """Obtiene el analista asignado para un agente en un ramo específico.

    La tabla asignacion define qué analista atiende a cada (agente, ramo).
    Si no hay asignación específica, retorna la asignación por defecto del ramo.

    Args:
        agente_id: UUID del agente de seguros.
        ramo: vida | gmm | autos | pyme.

    Returns: {"analista_id": "<uuid>", "gerente_id": "<uuid>",
              "tipo": "especifica"|"default"} o {"analista_id": null}
    """
    db = get_db()

    # Buscar asignación específica agente+ramo
    especifica = db.table("asignacion").select(
        "analista_id, gerente_id"
    ).eq("agente_id", agente_id).eq("ramo", ramo).eq("activo", True).maybe_single().execute()

    if especifica.data:
        return {
            "analista_id": especifica.data["analista_id"],
            "gerente_id": especifica.data.get("gerente_id"),
            "tipo": "especifica",
        }

    # Asignación por defecto del ramo (agente_id IS NULL)
    default = db.table("asignacion").select(
        "analista_id, gerente_id"
    ).is_("agente_id", "null").eq("ramo", ramo).eq("activo", True).maybe_single().execute()

    if default.data:
        return {
            "analista_id": default.data["analista_id"],
            "gerente_id": default.data.get("gerente_id"),
            "tipo": "default",
        }

    return {"analista_id": None, "gerente_id": None, "tipo": "sin_asignacion"}


@mcp.tool()
def asignar_analista_tramite(
    tramite_id: str,
    analista_id: str,
    agente_id: str | None = None,
    confianza_asignacion: float | None = None,
    metodo_asignacion: str = "cua_exacto",
) -> dict[str, Any]:
    """Asigna un analista al trámite y opcionalmente vincula el agente identificado.

    El Agente 4 llama esto después de completar la cascada CUA.
    El gerente_id se auto-asigna por trigger en la DB al asignar el analista.

    Args:
        tramite_id: UUID del trámite.
        analista_id: UUID del analista asignado.
        agente_id: UUID del agente de seguros identificado (opcional).
        confianza_asignacion: Score de confianza del Agente 4 (0.0-1.0).
        metodo_asignacion: 'cua_exacto' | 'fuzzy_nombre' | 'default_ramo' | 'manual'.

    Returns: {"ok": true}
    """
    db = get_db()
    payload: dict[str, Any] = {"analista_id": analista_id}
    if agente_id:
        payload["agente_id"] = agente_id
    if confianza_asignacion is not None:
        payload["confianza_asignacion"] = confianza_asignacion
    if metodo_asignacion:
        payload["metodo_asignacion"] = metodo_asignacion

    db.table("tramite").update(payload).eq("id", tramite_id).execute()
    return {"ok": True}


@mcp.tool()
def buscar_poliza_por_numero(
    numero_poliza: str,
    ramo: str | None = None,
) -> dict[str, Any]:
    """Busca una póliza por número en el catálogo del CRM.

    El Agente 4 la usa para vincular el trámite a una póliza existente
    cuando el agente menciona el número de póliza en el correo.

    Args:
        numero_poliza: Número de póliza tal como aparece en el correo/documentos.
        ramo: Filtrar por ramo para mayor precisión (opcional).

    Returns: {"poliza": {...}} o {"poliza": null}
    """
    db = get_db()
    query = db.table("poliza").select(
        "id, numero_poliza, ramo, estado, agente_id, analista_id, fecha_inicio, fecha_fin"
    ).eq("numero_poliza", numero_poliza)

    if ramo:
        query = query.eq("ramo", ramo)

    result = query.maybe_single().execute()
    return {"poliza": result.data}
