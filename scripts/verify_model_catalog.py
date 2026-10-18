"""Opt-in API checks using fixed synthetic text and generated speech only.

Does not start the workspace, recover jobs, retain audio, or inspect user content.
Output contains model IDs, stage names, and counts; never provider payloads.
"""
import argparse
import asyncio
import base64
from dataclasses import replace
import json
from pathlib import Path
from types import SimpleNamespace

import httpx

from server_workspace.run import load
from server_workspace.workspace import OpenAIProvider, WorkspaceConfig
from server_workspace.voice import OpenAIRealtimePeer, VoicePolicy
from server_workspace.voice_tools import VoiceTools, definitions


async def voice_check(workspace, model):
    peer = None
    stage = "connect"
    try:
        peer = await OpenAIRealtimePeer.open(workspace, model, "synthetic-model-check")
        stage = "session"
        await peer.send({"type": "session.update", "session": {
            "type": "realtime", "model": model, "output_modalities": ["audio"],
            "instructions": "Use the calculator for arithmetic. Answer briefly in English.",
            "tools": definitions({}, VoicePolicy()), "tool_choice": "auto", "max_output_tokens": 1024,
            "audio": {"input": {"format": {"type": "audio/pcm", "rate": 24000},
                                "transcription": {"model": "gpt-4o-mini-transcribe"},
                                "turn_detection": {"type": "semantic_vad", "eagerness": "medium",
                                                   "create_response": False, "interrupt_response": True}},
                      "output": {"format": {"type": "audio/pcm", "rate": 24000}, "voice": "marin"}}}})
        while True:
            event = await asyncio.wait_for(peer.receive(), 15)
            if event.get("type") == "error":
                return {"model": model, "passed": False, "stage": stage}
            if event.get("type") == "session.updated":
                break
        stage = "speech-and-tool"
        await peer.send({"type": "conversation.item.create", "item": {
            "type": "message", "role": "user", "content": [{"type": "input_text",
                "text": "Use the calculator tool to multiply 17 by 23. Then say the result in one short sentence."}]}})
        await peer.send({"type": "response.create"})
        audio, captions, calls = 0, "", 0
        tools = VoiceTools(workspace)
        for _ in range(400):
            event = await asyncio.wait_for(peer.receive(), 20)
            kind = event.get("type")
            if kind == "error":
                return {"model": model, "passed": False, "stage": stage}
            if kind == "response.output_audio.delta":
                audio += len(base64.b64decode(event["delta"]))
            if kind == "response.output_audio_transcript.done":
                captions += event.get("transcript", "")
            if kind != "response.done":
                continue
            response = event.get("response", {})
            tool_calls = [o for o in response.get("output", []) if o.get("type") == "function_call"]
            if not tool_calls:
                correct = "391" in captions or "three hundred and ninety" in captions.lower()
                return {"model": model, "passed": response.get("status") == "completed" and correct and audio > 0 and calls > 0,
                        "audio_bytes": audio, "caption_chars": len(captions), "tool_calls": calls}
            for call in tool_calls:
                if call["name"] != "calculate" or calls >= 3:
                    return {"model": model, "passed": False, "stage": "unexpected-tool"}
                result = await tools.execute("calculate", json.loads(call["arguments"]))
                calls += 1
                await peer.send({"type": "conversation.item.create", "item": {
                    "type": "function_call_output", "call_id": call["call_id"], "output": json.dumps(result)}})
            await peer.send({"type": "response.create"})
        return {"model": model, "passed": False, "stage": "event-limit"}
    except Exception:
        return {"model": model, "passed": False, "stage": stage}
    finally:
        if peer:
            await peer.close()


async def verify(path):
    approved = load(path)
    defaults = WorkspaceConfig(approved.root, approved.key_file)
    config = replace(approved, generation_models=defaults.generation_models,
                     transcription_models=defaults.transcription_models, voice_models=defaults.voice_models)
    provider = OpenAIProvider(config)
    workspace = SimpleNamespace(config=config, provider=provider)
    async with httpx.AsyncClient(timeout=120, follow_redirects=False, trust_env=False) as client:
        response = await client.get("https://api.openai.com/v1/models", headers=provider.headers())
        response.raise_for_status()
        ids = {x["id"] for x in response.json()["data"]}
        wanted = set(config.generation_models + config.transcription_models + config.voice_models)
        if not wanted <= ids:
            return {"passed": False, "stage": "catalog", "unavailable": sorted(wanted - ids)}
        response = await client.post("https://api.openai.com/v1/audio/speech", headers=provider.headers(), json={
            "model": "gpt-4o-mini-tts", "voice": "alloy", "response_format": "wav",
            "input": "Synthetic test. Jordan will send the agenda on Friday."})
        response.raise_for_status()
        audio = response.content
    results = {"generation": [], "transcription": [], "voice": []}
    for model in config.generation_models:
        try:
            text = await provider.generate(model, "Return only two bullet points, with no extra facts. Include each person, task, and full day name without abbreviations.",
                "Jordan will send the agenda on Friday. Avery will review the plan on Monday.", [])
            passed = all(term in text.lower() for term in ("friday", "monday", "agenda"))
            results["generation"].append({"model": model, "passed": passed, "answer_chars": len(text)})
        except Exception:
            results["generation"].append({"model": model, "passed": False, "stage": "generation"})
    for model in config.transcription_models:
        try:
            text = await provider.transcribe(audio, model, "Transcribe all audible speech. Synthetic test only.")
            passed = all(term in text.lower() for term in ("friday", "agenda"))
            results["transcription"].append({"model": model, "passed": passed, "transcript_chars": len(text)})
        except Exception:
            results["transcription"].append({"model": model, "passed": False, "stage": "transcription"})
    for model in config.voice_models:
        results["voice"].append(await asyncio.wait_for(voice_check(workspace, model), 90))
    return {"passed": all(r["passed"] for rows in results.values() for r in rows), "results": results}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--live", action="store_true", help="Explicitly authorize bounded synthetic provider requests")
    args = parser.parse_args()
    if not args.live:
        parser.error("Pass --live only for an authorized synthetic provider check")
    try:
        result = asyncio.run(verify(args.config))
    except Exception:
        result = {"passed": False, "stage": "catalog-or-synthetic-audio"}
    print(json.dumps(result))
    raise SystemExit(0 if result["passed"] else 1)
