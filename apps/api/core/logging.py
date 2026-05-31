"""
Configuración de observabilidad para Olimpo API.

- Logfire: trazas estructuradas de FastAPI + LLM calls (via LiteLLM)
- Sentry: captura de excepciones no manejadas
- structlog: logging estructurado en JSON para Railway logs

El setup se llama una sola vez desde el lifespan de FastAPI en main.py.
"""

import logging

import logfire
import sentry_sdk
import structlog
from sentry_sdk.integrations.fastapi import FastApiIntegration
from sentry_sdk.integrations.logging import LoggingIntegration

from core.config import get_settings


def setup_observability() -> None:
    s = get_settings()

    # -------------------------------------------------------------------------
    # Logfire — trazas de FastAPI y LLM calls
    # -------------------------------------------------------------------------
    if s.LOGFIRE_TOKEN:
        logfire.configure(
            token=s.LOGFIRE_TOKEN,
            service_name="olimpo-api",
            environment=s.ENVIRONMENT,
            send_to_logfire=True,
        )
    else:
        # En desarrollo sin token: logs locales en consola
        logfire.configure(send_to_logfire=False)

    # -------------------------------------------------------------------------
    # Sentry — errores y excepciones
    # -------------------------------------------------------------------------
    if s.SENTRY_DSN:
        sentry_sdk.init(
            dsn=s.SENTRY_DSN,
            environment=s.ENVIRONMENT,
            integrations=[
                FastApiIntegration(transaction_style="endpoint"),
                LoggingIntegration(level=logging.WARNING, event_level=logging.ERROR),
            ],
            traces_sample_rate=0.1 if s.is_production else 1.0,
            send_default_pii=False,
        )

    # -------------------------------------------------------------------------
    # structlog — logging estructurado en JSON
    # -------------------------------------------------------------------------
    structlog.configure(
        processors=[
            structlog.contextvars.merge_contextvars,
            structlog.stdlib.add_log_level,
            structlog.processors.TimeStamper(fmt="iso"),
            structlog.processors.StackInfoRenderer(),
            structlog.processors.format_exc_info,
            structlog.processors.JSONRenderer()
            if s.is_production
            else structlog.dev.ConsoleRenderer(),
        ],
        wrapper_class=structlog.make_filtering_bound_logger(logging.DEBUG),
        logger_factory=structlog.PrintLoggerFactory(),
        cache_logger_on_first_use=True,
    )
