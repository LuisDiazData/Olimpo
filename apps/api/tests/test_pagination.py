"""
Tests de PaginatedResponse — Capa 1 (sin DB).

Verifica la lógica de has_more, campos requeridos y compatibilidad con tipos genéricos.
"""

from models.pagination import PaginatedResponse
from models.tramite import TramiteListItem


class TestPaginatedResponseBuild:
    def test_primera_pagina_con_mas_resultados(self):
        items = ["a", "b", "c"]
        result = PaginatedResponse.build(items=items, total=10, offset=0, limit=3)

        assert result.items == items
        assert result.total == 10
        assert result.offset == 0
        assert result.limit == 3
        assert result.has_more is True

    def test_ultima_pagina_sin_mas_resultados(self):
        items = ["a", "b"]
        result = PaginatedResponse.build(items=items, total=5, offset=3, limit=5)

        assert result.has_more is False
        assert result.offset == 3

    def test_pagina_unica_completa(self):
        items = list(range(5))
        result = PaginatedResponse.build(items=items, total=5, offset=0, limit=10)

        assert result.has_more is False
        assert result.total == 5

    def test_lista_vacia_sin_mas_resultados(self):
        result = PaginatedResponse.build(items=[], total=0, offset=0, limit=50)

        assert result.items == []
        assert result.total == 0
        assert result.has_more is False

    def test_campos_presentes_en_serializacion(self):
        result = PaginatedResponse.build(items=[], total=100, offset=0, limit=50)
        data = result.model_dump()

        assert "items" in data
        assert "total" in data
        assert "offset" in data
        assert "limit" in data
        assert "has_more" in data

    def test_has_more_en_borde_exacto(self):
        # offset=5, limit=5, total=10 → offset + len(items) = 10 = total → NO has_more
        items = list(range(5))
        result = PaginatedResponse.build(items=items, total=10, offset=5, limit=5)
        assert result.has_more is False

    def test_has_more_un_elemento_mas(self):
        # offset=5, len(items)=5 → processed 10, total=11 → has_more
        items = list(range(5))
        result = PaginatedResponse.build(items=items, total=11, offset=5, limit=5)
        assert result.has_more is True

    def test_compatible_como_response_model_con_tipo_concreto(self):
        # Verificar que PaginatedResponse[TramiteListItem] es instanciable
        result = PaginatedResponse[TramiteListItem].build(items=[], total=0, offset=0, limit=50)
        assert result.total == 0
        assert result.items == []
