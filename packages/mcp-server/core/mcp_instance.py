from mcp.server.fastmcp import FastMCP

from core.config import get_settings

mcp = FastMCP(get_settings().MCP_SERVER_NAME)
