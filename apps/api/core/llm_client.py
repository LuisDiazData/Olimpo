"""
Cliente centralizado de IA para Olimpo CRM.

Gestione todas las llamadas a LLMs (Gemini y RunPod), generación de embeddings
y procesamiento de OCR a través de un único cliente unificado.
"""
from __future__ import annotations

import asyncio
import base64
import time
from typing import Any, cast

import httpx
import litellm
import structlog
from tenacity import retry, stop_after_attempt, wait_exponential

from core.config import get_settings

log = structlog.get_logger(__name__)

# Configurar LiteLLM para utilizar variables de entorno locales si están presentes
# y deshabilitar telemetría innecesaria
litellm.telemetry = False


class IAClientError(Exception):
    """Excepción base para errores en el cliente de IA."""
    pass


class OCRProcessingError(IAClientError):
    """Excepción para errores específicos del procesamiento de OCR."""
    pass


class LLMCompletionError(IAClientError):
    """Excepción para errores específicos al llamar a LLMs."""
    pass


class EmbeddingError(IAClientError):
    """Excepción para errores al generar embeddings."""
    pass


class IAClient:
    def __init__(self) -> None:
        self.settings = get_settings()
        self._setup_litellm_keys()

    def _setup_litellm_keys(self) -> None:
        """Configura las claves de API necesarias en LiteLLM."""
        if self.settings.GEMINI_API_KEY:
            litellm.gemini_key = self.settings.GEMINI_API_KEY
        if self.settings.OPENAI_API_KEY:
            litellm.openai_key = self.settings.OPENAI_API_KEY
        if self.settings.ANTHROPIC_API_KEY:
            litellm.anthropic_key = self.settings.ANTHROPIC_API_KEY

    @retry(
        stop=stop_after_attempt(3),
        wait=wait_exponential(multiplier=1, min=2, max=10),
        reraise=True,
    )
    async def completar_tarea_pesada(
        self,
        messages: list[dict[str, str]],
        temperature: float = 0.2,
        max_tokens: int = 4096,
        response_format: dict[str, Any] | None = None,
        model_override: str | None = None,
    ) -> str:
        """
        Llama al LLM de razonamiento avanzado y contexto largo (Gemini).
        Por defecto usa gemini/gemini-2.0-flash para rapidez y eficiencia,
        pero puede usar gemini-2.0-pro o ser sobreescrito.
        """
        model = model_override or "gemini/gemini-2.0-flash"
        log.info("llamando_llm_pesado_inicio", model=model, temperature=temperature)
        
        try:
            # LiteLLM maneja la llamada de forma unificada
            response = await litellm.acompletion(
                model=model,
                messages=messages,
                temperature=temperature,
                max_tokens=max_tokens,
                response_format=response_format,
            )
            
            content = response.choices[0].message.content
            if not content:
                raise LLMCompletionError("El modelo retornó una respuesta vacía.")
            
            log.info("llamando_llm_pesado_exito", model=model, tokens_usados=response.usage.total_tokens)
            return content
        except Exception as e:
            log.error("llamando_llm_pesado_fallo", model=model, error=str(e))
            raise LLMCompletionError(f"Error en completar_tarea_pesada con {model}: {e}") from e

    @retry(
        stop=stop_after_attempt(3),
        wait=wait_exponential(multiplier=1, min=2, max=10),
        reraise=True,
    )
    async def completar_tarea_liviana(
        self,
        messages: list[dict[str, str]],
        temperature: float = 0.2,
        max_tokens: int = 1024,
        endpoint_id_override: str | None = None,
        timeout_seconds: int = 120,
    ) -> str:
        """
        Llama al LLM liviano alojado en RunPod Serverless usando la API asíncrona v2.
        Envía la petición a /run, hace polling de /status y retorna el texto generado.
        """
        endpoint_url = self.settings.RUNPOD_ENDPOINT_OCR
        api_key = self.settings.RUNPOD_API_KEY
        
        endpoint_id = endpoint_id_override or self._extract_endpoint_id(endpoint_url)
        if not endpoint_id or not api_key:
            raise LLMCompletionError("Falta la configuración de RUNPOD_ENDPOINT_OCR o RUNPOD_API_KEY.")

        base_endpoint = f"https://api.runpod.ai/v2/{endpoint_id}"
        run_url = f"{base_endpoint}/run"
        
        # Formatear prompt
        prompt = ""
        if len(messages) == 1:
            prompt = messages[0]["content"]
        else:
            for msg in messages:
                role = msg["role"]
                content = msg["content"]
                prompt += f"<|im_start|>{role}\n{content}<|im_end|>\n"
            prompt += "<|im_start|>assistant\n"

        payload = {
            "input": {
                "prompt": prompt,
                "max_tokens": max_tokens,
                "temperature": temperature,
            }
        }
        
        headers = {
            "Content-Type": "application/json",
            "Authorization": f"Bearer {api_key}"
        }
        
        log.info("completar_tarea_liviana_runpod_inicio", endpoint_id=endpoint_id, prompt_len=len(prompt))
        
        async with httpx.AsyncClient(timeout=30.0) as client:
            try:
                response = await client.post(run_url, json=payload, headers=headers)
                if response.status_code != 200:
                    raise LLMCompletionError(f"RunPod devolvió código de error {response.status_code}: {response.text}")
                
                job_data = response.json()
                job_id = job_data.get("id")
                
                if not job_id:
                    raise LLMCompletionError(f"No se recibió Job ID de RunPod: {job_data}")
                
                log.info("completar_tarea_liviana_runpod_encolado", job_id=job_id)
                
                status_url = f"{base_endpoint}/status/{job_id}"
                start_time = time.time()
                poll_interval = 2.0
                
                while time.time() - start_time < timeout_seconds:
                    status_response = await client.get(status_url, headers=headers)
                    if status_response.status_code != 200:
                        raise LLMCompletionError(f"Error al verificar estado en RunPod: {status_response.text}")
                    
                    status_data = status_response.json()
                    current_status = status_data.get("status")
                    
                    log.debug("completar_tarea_liviana_runpod_polling", job_id=job_id, status=current_status)
                    
                    if current_status == "COMPLETED":
                        output = status_data.get("output", "")
                        texto_generado = self._parse_llm_output(output)
                        log.info("completar_tarea_liviana_runpod_exito", job_id=job_id, chars=len(texto_generado))
                        return texto_generado
                    
                    elif current_status == "FAILED":
                        error_msg = status_data.get("error", "Error desconocido en el worker de RunPod.")
                        raise LLMCompletionError(f"La tarea de RunPod falló: {error_msg}")
                    
                    elif current_status == "CANCELLED":
                        raise LLMCompletionError("La tarea de RunPod fue cancelada.")
                    
                    await asyncio.sleep(poll_interval)
                    poll_interval = min(poll_interval * 1.5, 10.0)
                
                raise LLMCompletionError(f"Tiempo de espera agotado ({timeout_seconds}s) en RunPod.")
                
            except httpx.HTTPError as he:
                log.error("completar_tarea_liviana_runpod_http_error", error=str(he))
                raise LLMCompletionError(f"Error de red al comunicar con RunPod: {he}") from he


    @retry(
        stop=stop_after_attempt(3),
        wait=wait_exponential(multiplier=1, min=2, max=10),
        reraise=True,
    )
    async def generar_embedding(
        self,
        texto: str,
        model: str = "text-embedding-3-small",
    ) -> list[float]:
        """
        Genera un vector (embedding) para un texto dado.
        Por defecto utiliza text-embedding-3-small de OpenAI (1536 dimensiones).
        Si falla o no está configurado, realiza fallback a Gemini embedding (768 dimensiones).
        """
        log.info("generar_embedding_inicio", model=model, longitud_texto=len(texto))
        
        try:
            # Si se usa OpenAI
            if "openai" in model or model.startswith("text-embedding"):
                if not self.settings.OPENAI_API_KEY:
                    log.warning("openai_key_ausente_intentando_fallback_gemini")
                    return await self._generar_embedding_gemini(texto)
                
                response = await litellm.aembedding(
                    model=model,
                    input=[texto],
                )
                embedding = response.data[0]["embedding"]
                log.info("generar_embedding_exito", model=model, dim=len(embedding))
                return cast(list[float], embedding)
            else:
                return await self._generar_embedding_gemini(texto)
        except Exception as e:
            log.error("generar_embedding_fallo", model=model, error=str(e))
            # Fallback automático ante cualquier excepción
            try:
                log.warning("reintentando_embedding_con_gemini_fallback")
                return await self._generar_embedding_gemini(texto)
            except Exception as fe:
                raise EmbeddingError(f"Error al generar embedding: {fe}") from fe

    async def _generar_embedding_gemini(self, texto: str) -> list[float]:
        """Generación de embeddings de respaldo usando el modelo de Gemini."""
        model = "gemini/text-embedding-004"
        response = await litellm.aembedding(
            model=model,
            input=[texto],
        )
        embedding = response.data[0]["embedding"]
        log.info("generar_embedding_gemini_exito", model=model, dim=len(embedding))
        return cast(list[float], embedding)

    async def ejecutar_ocr(
        self,
        documento_bytes: bytes,
        nombre_archivo: str = "documento.pdf",
        mime_type: str = "application/pdf",
        timeout_seconds: int = 120,
    ) -> str:
        """
        Envía un documento (PDF o Imagen) al endpoint de RunPod para realizar OCR.
        Realiza la subida en base64, encola la tarea, hace polling de su estado
        y retorna el texto estructurado extraído.
        """
        endpoint_url = self.settings.RUNPOD_ENDPOINT_OCR
        api_key = self.settings.RUNPOD_API_KEY
        
        if not endpoint_url or not api_key:
            raise OCRProcessingError("Falta configuración de RUNPOD_ENDPOINT_OCR o RUNPOD_API_KEY.")
        
        # Si la URL termina en /run o /status, la normalizamos para obtener el host base
        # Ej: https://api.runpod.ai/v2/owdtacb3y3tnj0/run -> base
        base_endpoint = endpoint_url
        if endpoint_url.endswith("/run"):
            base_endpoint = endpoint_url[:-4]
        
        run_url = f"{base_endpoint}/run"
        
        # Codificar el documento en base64
        doc_b64 = base64.b64encode(documento_bytes).decode("utf-8")
        
        payload = {
            "input": {
                "documento_base64": doc_b64,
                "nombre_archivo": nombre_archivo,
                "mime_type": mime_type,
            }
        }
        
        headers = {
            "Content-Type": "application/json",
            "Authorization": f"Bearer {api_key}"
        }
        
        log.info("ocr_runpod_iniciar", archivo=nombre_archivo, size_bytes=len(documento_bytes))
        
        async with httpx.AsyncClient(timeout=30.0) as client:
            try:
                # 1. Encolar la tarea
                response = await client.post(run_url, json=payload, headers=headers)
                if response.status_code != 200:
                    raise OCRProcessingError(f"RunPod devolvió código de error {response.status_code}: {response.text}")
                
                job_data = response.json()
                job_id = job_data.get("id")
                status = job_data.get("status")
                
                if not job_id:
                    raise OCRProcessingError(f"No se recibió Job ID de RunPod: {job_data}")
                
                log.info("ocr_runpod_encolado", job_id=job_id, status=status)
                
                # 2. Polling de la tarea
                status_url = f"{base_endpoint}/status/{job_id}"
                start_time = time.time()
                poll_interval = 2.0
                
                while time.time() - start_time < timeout_seconds:
                    status_response = await client.get(status_url, headers=headers)
                    if status_response.status_code != 200:
                        raise OCRProcessingError(f"Error al verificar estado: {status_response.text}")
                    
                    status_data = status_response.json()
                    current_status = status_data.get("status")
                    
                    log.debug("ocr_runpod_polling", job_id=job_id, status=current_status)
                    
                    if current_status == "COMPLETED":
                        # Extraer el resultado
                        output = status_data.get("output", "")
                        # Si el output viene estructurado en una lista/dict de vLLM o custom
                        texto_extraido = self._parse_ocr_output(output)
                        log.info("ocr_runpod_completado", job_id=job_id, chars=len(texto_extraido))
                        return texto_extraido
                    
                    elif current_status == "FAILED":
                        error_msg = status_data.get("error", "Error desconocido en el worker de RunPod.")
                        raise OCRProcessingError(f"El procesamiento del OCR falló en RunPod: {error_msg}")
                    
                    elif current_status == "CANCELLED":
                        raise OCRProcessingError("El procesamiento del OCR fue cancelado en RunPod.")
                    
                    # Backoff exponencial suave para no saturar la API
                    await asyncio.sleep(poll_interval)
                    poll_interval = min(poll_interval * 1.5, 10.0)
                
                raise OCRProcessingError(f"Tiempo de espera agotado ({timeout_seconds}s) esperando el OCR en RunPod.")
                
            except httpx.HTTPError as he:
                log.error("ocr_runpod_http_error", error=str(he))
                raise OCRProcessingError(f"Error de red al comunicar con RunPod: {he}") from he

    def _parse_ocr_output(self, output: Any) -> str:
        """Parsea la respuesta del endpoint de OCR para extraer el texto legible."""
        if isinstance(output, str):
            return output
        elif isinstance(output, dict):
            # Formatos comunes de salida
            if "text" in output:
                return str(output["text"])
            elif "content" in output:
                return str(output["content"])
            elif "choices" in output:
                # Respuesta típica de vLLM
                return str(output["choices"][0]["message"]["content"])
        elif isinstance(output, list) and len(output) > 0:
            return self._parse_ocr_output(output[0])
            
        return str(output)

    def _parse_llm_output(self, output: Any) -> str:
        """Parsea la salida del LLM de RunPod, manejando múltiples formatos."""
        if isinstance(output, str):
            return output
        elif isinstance(output, list) and len(output) > 0:
            first = output[0]
            if isinstance(first, dict) and "choices" in first:
                choices = first["choices"]
                if len(choices) > 0:
                    choice = choices[0]
                    if "tokens" in choice:
                        tokens = choice["tokens"]
                        if isinstance(tokens, list):
                            return "".join(tokens)
                        return str(tokens)
                    elif "text" in choice:
                        return str(choice["text"])
                    elif "message" in choice and "content" in choice["message"]:
                        return str(choice["message"]["content"])
            return self._parse_llm_output(first)
        elif isinstance(output, dict):
            if "choices" in output:
                choices = output["choices"]
                if len(choices) > 0:
                    choice = choices[0]
                    if "text" in choice:
                        return str(choice["text"])
                    elif "message" in choice and "content" in choice["message"]:
                        return str(choice["message"]["content"])
            elif "text" in output:
                return str(output["text"])
        return str(output)

    def _extract_endpoint_id(self, url: str) -> str | None:
        """Extrae el endpoint ID de una URL de RunPod."""
        # Ej: https://api.runpod.ai/v2/owdtacb3y3tnj0/run -> owdtacb3y3tnj0
        if not url:
            return None
        parts = url.split("/")
        # Buscar el segmento después de v2
        for i, part in enumerate(parts):
            if part == "v2" and i + 1 < len(parts):
                return parts[i + 1]
        # Fallback simple
        return parts[-2] if len(parts) >= 2 else None


# Instancia única compartida (Singleton)
_client_instance: IAClient | None = None


def get_ia_client() -> IAClient:
    """Retorna la instancia singleton del cliente de IA."""
    global _client_instance
    if _client_instance is None:
        _client_instance = IAClient()
    return _client_instance
