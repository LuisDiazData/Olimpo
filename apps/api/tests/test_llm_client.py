import pytest
from unittest.mock import AsyncMock, MagicMock, patch

from core.llm_client import IAClient, get_ia_client, IAClientError, OCRProcessingError


@pytest.fixture
def mock_settings():
    with patch("core.llm_client.get_settings") as mock_get:
        settings_instance = MagicMock()
        settings_instance.GEMINI_API_KEY = "test-gemini-key"
        settings_instance.OPENAI_API_KEY = "test-openai-key"
        settings_instance.ANTHROPIC_API_KEY = "test-anthropic-key"
        settings_instance.RUNPOD_API_KEY = "test-runpod-key"
        settings_instance.RUNPOD_ENDPOINT_OCR = "https://api.runpod.ai/v2/test-endpoint/run"
        mock_get.return_value = settings_instance
        yield settings_instance


@pytest.mark.asyncio
async def test_completar_tarea_pesada(mock_settings):
    client = IAClient()
    
    # Mockear acompletion de litellm
    mock_response = MagicMock()
    mock_response.choices = [MagicMock()]
    mock_response.choices[0].message.content = "Esta es una respuesta pesada de prueba"
    mock_response.usage.total_tokens = 120
    
    with patch("litellm.acompletion", new_callable=AsyncMock) as mock_acompletion:
        mock_acompletion.return_value = mock_response
        
        messages = [{"role": "user", "content": "Hola"}]
        result = await client.completar_tarea_pesada(messages=messages)
        
        assert result == "Esta es una respuesta pesada de prueba"
        mock_acompletion.assert_called_once()
        assert mock_acompletion.call_args[1]["model"] == "gemini/gemini-1.5-flash"


@pytest.mark.asyncio
async def test_completar_tarea_liviana(mock_settings):
    client = IAClient()
    
    mock_response = MagicMock()
    mock_response.choices = [MagicMock()]
    mock_response.choices[0].message.content = "Esta es una respuesta liviana de prueba"
    
    with patch("litellm.acompletion", new_callable=AsyncMock) as mock_acompletion:
        mock_acompletion.return_value = mock_response
        
        messages = [{"role": "user", "content": "Hola"}]
        result = await client.completar_tarea_liviana(messages=messages)
        
        assert result == "Esta es una respuesta liviana de prueba"
        mock_acompletion.assert_called_once()
        assert "runpod/test-endpoint" in mock_acompletion.call_args[1]["model"]


@pytest.mark.asyncio
async def test_generar_embedding(mock_settings):
    client = IAClient()
    
    mock_response = {
        "data": [
            {"embedding": [0.1, 0.2, 0.3]}
        ]
    }
    
    with patch("litellm.aembedding", new_callable=AsyncMock) as mock_aembedding:
        mock_aembedding.return_value = mock_response
        
        embedding = await client.generar_embedding("texto de prueba")
        
        assert embedding == [0.1, 0.2, 0.3]
        mock_aembedding.assert_called_once()
        assert mock_aembedding.call_args[1]["model"] == "text-embedding-3-small"


@pytest.mark.asyncio
async def test_ejecutar_ocr_exito(mock_settings):
    client = IAClient()
    
    # Mockear httpx.AsyncClient
    with patch("httpx.AsyncClient.post", new_callable=AsyncMock) as mock_post, \
         patch("httpx.AsyncClient.get", new_callable=AsyncMock) as mock_get:
         
        # Mock de post (encolar tarea)
        mock_post.return_value = MagicMock(
            status_code=200,
            json=MagicMock(return_value={"id": "job_123", "status": "IN_QUEUE"})
        )
        
        # Mock de get (polling status)
        mock_get.return_value = MagicMock(
            status_code=200,
            json=MagicMock(return_value={"status": "COMPLETED", "output": "Texto de OCR de prueba"})
        )
        
        result = await client.ejecutar_ocr(b"pdfdata", "doc.pdf")
        
        assert result == "Texto de OCR de prueba"
        mock_post.assert_called_once()
        mock_get.assert_called_once()
