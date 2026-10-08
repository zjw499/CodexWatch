import asyncio
import json
from types import SimpleNamespace

import httpx
import pytest

from server_workspace.voice import VoicePolicy
from server_workspace.voice_tools import VoiceTools, calculate, definitions, safe_source


def test_calculator_is_bounded_arithmetic_without_code_execution():
    assert calculate("(15+5)*3/4") == 15
    assert calculate("2**8") == 256
    for expression in ("__import__('os').system('echo unsafe')", "1/0", "2**100000000", "1e999", "True", "[1]*100", "(1).__class__"):
        with pytest.raises((ValueError, SyntaxError, ArithmeticError)):
            calculate(expression)


def test_tool_allowlist_requires_both_assistant_and_organization_web_setting():
    enabled = VoicePolicy(public_web_search_enabled=True)
    assert {d["name"] for d in definitions({}, enabled)} == {"calculate", "current_time"}
    assert len(definitions({"web_search": True}, enabled)) == 3
    assert len(definitions({"web_search": True}, VoicePolicy())) == 2
    assert definitions({"tools_enabled": False, "web_search": True}, enabled) == []


def test_web_request_contains_only_query_and_returns_clickable_citations(monkeypatch):
    received = []
    def handle(request):
        received.append(json.loads(request.content))
        if "tools" not in received[-1]:
            return httpx.Response(200, json={"status": "completed", "output": [{"type": "message", "content": [{"type": "output_text", "text": '{"public":true}'}]}]})
        return httpx.Response(200, json={"status": "completed", "output": [
            {"type": "web_search_call"}, {"type": "message", "content": [{"type": "output_text", "text": "Public fact.",
            "annotations": [{"type": "url_citation", "url": "https://example.org/source", "title": "Source"},
                            {"type": "url_citation", "url": "javascript:unsafe", "title": "Bad"}]}]}]})
    original = httpx.AsyncClient
    monkeypatch.setattr(httpx, "AsyncClient", lambda **kw: original(transport=httpx.MockTransport(handle), **kw))
    w = SimpleNamespace(config=SimpleNamespace(generation_models=("approved-model",)),
                        provider=SimpleNamespace(headers=lambda: {"Authorization": "synthetic-fixture"}))
    result = asyncio.run(VoiceTools(w).execute("search_web", {"query": "public weather"}))
    assert result["text"] == "Public fact."
    assert result["sources"] == [{"url": "https://example.org/source", "title": "Source"}]
    request = received[1]
    assert request["input"] == "public weather" and request["store"] is False
    assert request["model"] == "approved-model" and request["tools"][0]["type"] == "web_search"
    assert "previous_response_id" not in request and "conversation" not in request
    assert received[0]["store"] is False and "tools" not in received[0]


def test_private_query_is_rejected_before_any_search(monkeypatch):
    received = []
    def handle(request):
        received.append(json.loads(request.content))
        return httpx.Response(200, json={"status": "completed", "output": [{"type": "message", "content": [{"type": "output_text", "text": '{"public":false}'}]}]})
    original = httpx.AsyncClient
    monkeypatch.setattr(httpx, "AsyncClient", lambda **kw: original(transport=httpx.MockTransport(handle), **kw))
    w = SimpleNamespace(config=SimpleNamespace(generation_models=("approved-model",)), provider=SimpleNamespace(headers=lambda: {}))
    result = asyncio.run(VoiceTools(w).execute("search_web", {"query": "confidential patient details"}))
    assert "error" in result and len(received) == 1 and "tools" not in received[0]
    result = asyncio.run(VoiceTools(w).execute("search_web", {"query": "Find person@example.com"}))
    assert "error" in result and len(received) == 1


def test_tool_failures_and_unknown_actions_do_not_expose_provider_payloads(monkeypatch):
    def handle(_):
        return httpx.Response(403, json={"secret": "provider-private-payload"})
    original = httpx.AsyncClient
    monkeypatch.setattr(httpx, "AsyncClient", lambda **kw: original(transport=httpx.MockTransport(handle), **kw))
    w = SimpleNamespace(config=SimpleNamespace(generation_models=("approved-model",)),
                        provider=SimpleNamespace(headers=lambda: {}))
    tools = VoiceTools(w)
    result = asyncio.run(tools.execute("search_web", {"query": "news"}))
    assert "error" in result and "provider-private-payload" not in json.dumps(result)
    assert "error" in asyncio.run(tools.execute("send_email", {}))
    assert "error" in asyncio.run(tools.execute("calculate", {"expression": "1+1", "extra": True}))
    assert "error" in asyncio.run(tools.execute("current_time", {"timezone": "not-a-zone"}))
    assert asyncio.run(tools.execute("current_time", {"timezone": "UTC"}))["timezone"] == "UTC"


def test_source_links_reject_credentials_and_non_https():
    assert safe_source("https://example.com", "Example")
    for url in ("http://example.com", "https://user:secret@example.com", "file:///private", "javascript:unsafe"):
        assert safe_source(url, "Source") is None
