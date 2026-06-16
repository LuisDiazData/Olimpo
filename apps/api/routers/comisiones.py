from datetime import date

import structlog
from fastapi import APIRouter, Depends, HTTPException, status, UploadFile, File, Form
from supabase import Client

from core.auth import require_roles
from core.database import get_db
from models.usuario import RolUsuario
from models.comision import EstadoCuentaResponse
from celery_app import celery_app

log = structlog.get_logger(__name__)
router = APIRouter(tags=["Comisiones"])

_require_comisiones = require_roles(
    RolUsuario.director_general, RolUsuario.director_ops, RolUsuario.analista
)


@router.get("/comisiones/estados-cuenta", response_model=list[EstadoCuentaResponse])
def listar_estados_cuenta(
    db: Client = Depends(get_db),
    _=Depends(_require_comisiones),
):
    """Lista todos los estados de cuenta subidos."""
    res = db.table("comision_estado_cuenta").select("*").order("creado_en", desc=True).execute()
    return res.data


@router.post("/comisiones/upload", status_code=status.HTTP_202_ACCEPTED)
async def subir_estado_cuenta(
    aseguradora: str = Form(...),
    file: UploadFile = File(...),
    db: Client = Depends(get_db),
    user=Depends(_require_comisiones),
):
    """Sube un archivo de comisiones a Storage y encola su procesamiento en Celery."""
    # 1. Validar archivo
    if not file.filename or not file.filename.endswith((".pdf", ".xlsx", ".csv")):
        raise HTTPException(status_code=400, detail="Formato no soportado (PDF, XLSX o CSV).")

    # 2. Subir a Storage. Si falla, NO creamos un registro huérfano.
    file_bytes = await file.read()
    file_path = f"{aseguradora}/{user.id}/{file.filename}"
    try:
        db.storage.from_("comisiones").upload(file_path, file_bytes)
    except Exception as exc:
        log.error("error_subida_comisiones_storage", path=file_path, error=str(exc))
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail="No se pudo subir el archivo a Storage. Verifica que el bucket 'comisiones' exista.",
        )

    # 3. Crear registro en BD
    payload = {
        "aseguradora_id": aseguradora,
        "fecha_corte": date.today().isoformat(),
        "archivo_url": file_path,
        "estado": "pendiente",
        "procesado_por": str(user.id),
    }
    res = db.table("comision_estado_cuenta").insert(payload).execute()
    if not res.data:
        raise HTTPException(status_code=500, detail="No se pudo registrar el estado de cuenta.")
    estado_cuenta_id = res.data[0]["id"]

    # 4. Encolar tarea en Celery por nombre (consistente con el resto de routers).
    celery_app.send_task(
        "comisiones.procesar_estado_cuenta",
        args=[estado_cuenta_id, file_path],
        queue="procesamiento",
    )

    return {"message": "Archivo subido. Procesamiento en background.", "estado_cuenta_id": estado_cuenta_id}


@router.get("/comisiones/dashboard")
def obtener_dashboard(
    db: Client = Depends(get_db),
    _=Depends(_require_comisiones),
):
    """Resumen financiero agregado a partir de los recibos de comisión reales."""
    recibos = db.table("comision_recibo").select(
        "comision_promotoria, comision_agente, comision_total, es_estorno"
    ).execute().data or []

    comision_promotoria = sum(float(r.get("comision_promotoria") or 0) for r in recibos if not r.get("es_estorno"))
    comision_agentes = sum(float(r.get("comision_agente") or 0) for r in recibos if not r.get("es_estorno"))
    estornos = sum(float(r.get("comision_total") or 0) for r in recibos if r.get("es_estorno"))

    return {
        "comision_promotoria_mensual": round(comision_promotoria, 2),
        "comision_agentes_mensual": round(comision_agentes, 2),
        "estornos_pendientes": round(estornos, 2),
        "meta_bono_progreso": 0,  # Cálculo de metas/bonos pendiente de implementar.
    }
