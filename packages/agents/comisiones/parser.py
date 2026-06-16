import structlog
from celery import shared_task
from core.database import get_admin_db

log = structlog.get_logger(__name__)

@shared_task(name="comisiones.procesar_estado_cuenta")
def procesar_estado_cuenta(estado_cuenta_id: str, file_path: str):
    """
    Worker asíncrono de Celery que procesa el estado de cuenta.
    Esta función es pesada en CPU e I/O, por lo que corre fuera de FastAPI.
    """
    log.info("iniciando_procesamiento_comisiones", estado_cuenta_id=estado_cuenta_id)
    
    db = get_admin_db()
    
    try:
        # 1. Marcar como procesando
        db.table("comision_estado_cuenta").update({"estado": "procesando"}).eq("id", estado_cuenta_id).execute()
        
        # PLACEHOLDER: el parser real por aseguradora aún no está implementado.
        # Pasos pendientes:
        #   2. Descargar archivo: db.storage.from_("comisiones").download(file_path)
        #   3. Parsear (openpyxl/pymupdf/OCR) según aseguradora
        #   4. Conciliar pólizas (poliza_id por numero_poliza_texto)
        #   5. Calcular splits leyendo comision_split_regla
        #
        # NO insertamos recibos ficticios: marcamos el estado de cuenta como
        # procesado con totales en cero hasta que exista el parser real.
        db.table("comision_estado_cuenta").update({
            "estado": "procesado",
            "monto_total": 0
        }).eq("id", estado_cuenta_id).execute()

        log.warning(
            "comisiones_parser_placeholder",
            estado_cuenta_id=estado_cuenta_id,
            detalle="Parser de estado de cuenta no implementado; no se generaron recibos.",
        )
        
    except Exception as e:
        log.error("error_procesando_comisiones", estado_cuenta_id=estado_cuenta_id, error=str(e))
        db.table("comision_estado_cuenta").update({"estado": "error"}).eq("id", estado_cuenta_id).execute()
        raise e
