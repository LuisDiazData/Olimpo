"""
Construcción segura de filtros de búsqueda para PostgREST.

El texto de búsqueda libre que envía el usuario NUNCA debe interpolarse crudo en
una expresión `.or_(...)` de PostgREST: caracteres como `,` `.` `(` `)` `:` son
sintaxis de filtros y permitirían inyectar condiciones adicionales (leer columnas
no expuestas, alterar el alcance del query, etc.).

PostgREST permite envolver el valor entre comillas dobles para tratar esos
metacaracteres como literales. Aquí escapamos `\\` y `"` dentro del valor y lo
envolvemos en comillas, neutralizando la inyección y preservando el wildcard `%`.
"""


def filtro_busqueda_or(q: str, *columnas: str) -> str:
    """
    Devuelve una expresión OR de PostgREST para buscar `q` (ILIKE) en `columnas`.

    Ejemplo:
        filtro_busqueda_or("acme", "nombre", "cua")
        -> 'nombre.ilike."%acme%",cua.ilike."%acme%"'

    El valor se escapa y entrecomilla para que comas, puntos o paréntesis dentro
    del término no rompan ni inyecten estructura de filtro.
    """
    valor = q.replace("\\", "\\\\").replace('"', '\\"')
    return ",".join(f'{col}.ilike."%{valor}%"' for col in columnas)
