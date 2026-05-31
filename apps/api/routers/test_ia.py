"""
Router de diagnóstico para probar el cliente centralizado de IA.

Proporciona endpoints HTTP para validar la conectividad con Gemini, RunPod,
generación de embeddings y procesamiento de OCR.
Excluido en producción o protegido.
"""

from fastapi import APIRouter, Depends, HTTPException, UploadFile, File, status
from pydantic import BaseModel, Field

from core.auth import get_current_user_or_agent, require_roles
from core.config import get_settings
from core.llm_client import get_ia_client, IAClientError
from models.usuario import RolUsuario, UsuarioToken

router = APIRouter(prefix="/test/ia", tags=["diagnostico-ia"])

class CompletionTestRequest(BaseModel):
    prompt: str = Field(min_length=1, description="Texto de entrada para el modelo.")
    modelo_tipo: str = Field(default="pesado", description="Tipo de modelo: 'pesado' (Gemini) o 'liviano' (RunPod).")


class EmbeddingTestRequest(BaseModel):
    texto: str = Field(min_length=1, description="Texto para generar su embedding.")


# Endpoints protegidos para administradores y directores en desarrollo/staging
_DEPENDENCIAS_SEGURIDAD = [
    Depends(get_current_user_or_agent)
]


@router.post(
    "/completion",
    summary="Probar inferencia de LLM (Gemini o RunPod)",
    dependencies=_DEPENDENCIAS_SEGURIDAD,
)
async def test_completion(body: CompletionTestRequest):
    client = get_ia_client()
    messages = [{"role": "user", "content": body.prompt}]
    
    try:
        if body.modelo_tipo == "pesado":
            resultado = await client.completar_tarea_pesada(messages=messages)
        elif body.modelo_tipo == "liviano":
            resultado = await client.completar_tarea_liviana(messages=messages)
        else:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Tipo de modelo inválido. Debe ser 'pesado' o 'liviano'."
            )
        return {"resultado": resultado, "modelo_tipo": body.modelo_tipo}
    except IAClientError as e:
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail=f"Fallo en la comunicación con el LLM: {str(e)}"
        )


@router.post(
    "/embedding",
    summary="Probar generación de embeddings",
    dependencies=_DEPENDENCIAS_SEGURIDAD,
)
async def test_embedding(body: EmbeddingTestRequest):
    client = get_ia_client()
    try:
        vector = await client.generar_embedding(body.texto)
        return {
            "dimensiones": len(vector),
            "valores_preview": vector[:5],
            "valores": vector
        }
    except IAClientError as e:
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail=f"Fallo al generar el embedding: {str(e)}"
        )


@router.post(
    "/ocr",
    summary="Probar procesamiento OCR en RunPod",
    dependencies=_DEPENDENCIAS_SEGURIDAD,
)
async def test_ocr(file: UploadFile = File(...)):
    client = get_ia_client()
    
    # Validar formato
    if file.content_type not in ["application/pdf", "image/jpeg", "image/png"]:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Formato de archivo no soportado. Debe ser PDF, JPEG o PNG."
        )
        
    try:
        contenido_bytes = await file.read()
        texto_extraido = await client.ejecutar_ocr(
            documento_bytes=contenido_bytes,
            nombre_archivo=file.filename or "archivo",
            mime_type=file.content_type or "application/pdf"
        )
        return {
            "archivo": file.filename,
            "tamaño_bytes": len(contenido_bytes),
            "caracteres_extraidos": len(texto_extraido),
            "texto_extraido": texto_extraido
        }
    except IAClientError as e:
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail=f"Fallo al procesar el OCR: {str(e)}"
        )
