import sys
from pathlib import Path
from celery import Celery
import structlog

# Add the packages directory to PYTHONPATH so that celery can import from it
root_dir = Path(__file__).resolve().parent.parent.parent
packages_dir = root_dir / "packages"
if str(packages_dir) not in sys.path:
    sys.path.insert(0, str(packages_dir))

from core.config import get_settings

log = structlog.get_logger(__name__)
settings = get_settings()

# Módulos de tareas: los agentes viven en archivos agente_N_*.py (no en tasks.py),
# por lo que autodiscover_tasks no los encuentra. Los registramos explícitamente
# con `include` para que sus decoradores @task corran al arrancar el worker.
TASK_MODULES = [
    "agents.agente_0_renovaciones",
    "agents.agente_1_ingesta",
    "agents.agente_2_comprension",
    "agents.agente_3_ocr",
    "agents.agente_4_asignacion",
    "agents.agente_5_validacion",
    "agents.agente_6_redaccion",
    "agents.agente_7_marketing",
    "agents.comisiones.parser",
]

celery_app = Celery(
    "olimpo_celery",
    broker=settings.CELERY_BROKER_URL,
    backend=settings.CELERY_RESULT_BACKEND,
    include=TASK_MODULES,
)

celery_app.conf.update(
    task_serializer="json",
    accept_content=["json"],
    result_serializer="json",
    timezone="America/Mexico_City",
    enable_utc=True,
    # Cola única 'procesamiento'. Arrancar el worker con:
    #   celery -A celery_app worker -Q procesamiento
    task_routes={
        "agentes.*": {"queue": "procesamiento"},
        "comisiones.*": {"queue": "procesamiento"},
    },
)

from celery.schedules import crontab

celery_app.conf.beat_schedule = {
    "procesar-renovaciones-diarias": {
        "task": "agentes.agente_0_renovaciones.procesar",
        "schedule": crontab(hour=2, minute=0),
    },
}

if __name__ == "__main__":
    celery_app.start()
