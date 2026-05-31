"""
Olimpo MCP Server — Punto de entrada.

Expone herramientas de base de datos para los 6 agentes IA del pipeline:
  Agente 1 — Ingesta de correos y adjuntos
  Agente 2 — Comprensión y creación de trámites
  Agente 3 — OCR y clasificación de documentos
  Agente 4 — Identificación y asignación de agentes
  Agente 5 — Validación con RAG y aprendizaje
  Agente 6 — Redacción de correos de respuesta

Arranque:
  python server.py               # stdio (para Claude Desktop / subprocess)
  python server.py --transport sse --port 8001  # SSE (para integraciones HTTP)

Variables de entorno requeridas:
  SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY
"""

import argparse

import structlog

# Importar la instancia MCP primero (antes de los módulos de tools)
from core.mcp_instance import mcp  # noqa: F401

# Registrar herramientas de cada agente (importar activa los decoradores @mcp.tool())
import tools.asignacion  # noqa: F401
import tools.comun  # noqa: F401
import tools.comprension  # noqa: F401
import tools.ingesta  # noqa: F401
import tools.ocr_clasificacion  # noqa: F401
import tools.redaccion  # noqa: F401
import tools.validacion  # noqa: F401

log = structlog.get_logger(__name__)


def main() -> None:
    parser = argparse.ArgumentParser(description="Olimpo MCP Server")
    parser.add_argument(
        "--transport",
        choices=["stdio", "sse"],
        default="stdio",
        help="Transporte MCP: stdio (default) para Claude Desktop / subprocess; "
             "sse para integraciones HTTP.",
    )
    parser.add_argument(
        "--port",
        type=int,
        default=8001,
        help="Puerto para el transporte SSE (default 8001). Solo aplica con --transport sse.",
    )
    args = parser.parse_args()

    log.info("olimpo_mcp_arrancando", transport=args.transport)

    if args.transport == "sse":
        mcp.run(transport="sse", host="0.0.0.0", port=args.port)
    else:
        mcp.run(transport="stdio")


if __name__ == "__main__":
    main()
