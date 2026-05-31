"""
Wrapper de paginación para todos los endpoints de lista.

Uso:
    @router.get("", response_model=PaginatedResponse[TramiteListItem])
    async def listar_tramites(...) -> PaginatedResponse[TramiteListItem]:
        ...
        return PaginatedResponse.build(items=items, total=total, offset=offset, limit=limit)
"""

from typing import TypeVar

from pydantic import BaseModel, Field

T = TypeVar("T")


class PaginatedResponse[T](BaseModel):
    """
    Envuelve cualquier lista con metadatos de paginación.
    Necesario para que agentes MCP sepan si existen más registros.
    """

    items: list[T] = Field(description="Registros de esta página.")
    total: int = Field(description="Total de registros que coinciden con los filtros aplicados.")
    offset: int = Field(description="Número de registros saltados (inicio de esta página).")
    limit: int = Field(description="Máximo de registros por página solicitado.")
    has_more: bool = Field(description="True si existen más registros después de esta página.")

    model_config = {"from_attributes": True}

    @classmethod
    def build(
        cls,
        *,
        items: list[T],
        total: int,
        offset: int,
        limit: int,
    ) -> "PaginatedResponse[T]":
        return cls(
            items=items,
            total=total,
            offset=offset,
            limit=limit,
            has_more=(offset + len(items)) < total,
        )
