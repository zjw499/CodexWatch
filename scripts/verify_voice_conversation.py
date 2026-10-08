"""Explicit opt-in live API check using only fixed synthetic public questions.

Does not start/recover the workspace, provision devices, retain audio, or inspect
real conversation text. Secrets and provider payloads never enter output.
"""
import argparse
import asyncio
import json
from pathlib import Path
from types import SimpleNamespace

from server_workspace.run import load
from server_workspace.workspace import OpenAIProvider
from server_workspace.voice import OpenAIRealtimePeer, VoicePolicy
from server_workspace.voice_tools import VoiceTools, definitions, CONVERSATION_INSTRUCTIONS


async def verify(path):
    config = load(path)
    w = SimpleNamespace(config=config, provider=OpenAIProvider(config))
    peer = await OpenAIRealtimePeer.open(w, config.voice_models[0], "synthetic-voice-verification")
    tools = VoiceTools(w)
    try:
        await peer.send({"type": "session.update", "session": {
            "type": "realtime", "model": config.voice_models[0], "output_modalities": ["audio"],
            "instructions": CONVERSATION_INSTRUCTIONS + "\nAnswer briefly in English, one sentence.",
            "tools": definitions({"web_search": True}, VoicePolicy(public_web_search_enabled=True)), "tool_choice": "auto",
            "max_output_tokens": 300,
            "audio": {"input": {"format": {"type": "audio/pcm", "rate": 24000}, "turn_detection": None},
                      "output": {"format": {"type": "audio/pcm", "rate": 24000}, "voice": "marin"}}}})
        while True:
            event = await asyncio.wait_for(peer.receive(), 12)
            if event.get("type") == "session.updated":
                break
            if event.get("type") == "error":
                return {"passed": False, "stage": "session", "code": event.get("error", {}).get("code")}
        results = []
        questions = ["What is 17 times 23? Use the calculator and answer in one sentence.",
                     "Now add 19 to that answer. Use the calculator.",
                     "Search the public web for which voices OpenAI currently recommends for Realtime voice quality. Use the official OpenAI documentation and answer in one short sentence."]
        for index, question in enumerate(questions):
            await peer.send({"type": "conversation.item.create", "item": {
                "type": "message", "role": "user", "content": [{"type": "input_text", "text": question}]}})
            await peer.send({"type": "response.create"})
            text, used, source_count = "", [], 0
            for _ in range(500):
                event = await asyncio.wait_for(peer.receive(), 30)
                if event.get("type") == "error":
                    return {"passed": False, "stage": "question-" + str(index+1), "code": event.get("error", {}).get("code")}
                if event.get("type") == "response.output_audio_transcript.done":
                    text += event.get("transcript", "")
                if event.get("type") != "response.done":
                    continue
                response = event.get("response", {})
                calls = [o for o in response.get("output", []) if o.get("type") == "function_call"]
                if not calls:
                    passed = response.get("status") == "completed" and bool(text)
                    if index == 0: passed = passed and ("391" in text or "three hundred" in text.lower())
                    if index == 1: passed = passed and ("410" in text or "four hundred" in text.lower())
                    if index == 2: passed = passed and "search_web" in used and source_count > 0
                    results.append({"question": index+1, "passed": passed, "tools": used, "caption_chars": len(text), "source_count": source_count})
                    break
                for call in calls:
                    result = await tools.execute(call["name"], json.loads(call["arguments"]))
                    used.append(call["name"])
                    source_count += len(result.get("sources", []))
                    if result.get("error"):
                        return {"passed": False, "stage": "tool-"+call["name"], "message": result["error"]}
                    await peer.send({"type": "conversation.item.create", "item": {
                        "type": "function_call_output", "call_id": call["call_id"], "output": json.dumps(result)}})
                await peer.send({"type": "response.create"})
            else:
                return {"passed": False, "stage": "event-limit"}
        return {"passed": all(r["passed"] for r in results), "results": results}
    finally:
        await peer.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--live", action="store_true", help="Authorize this bounded public API check")
    args = parser.parse_args()
    if not args.live:
        parser.error("Live API checks require --live")
    try:
        result = asyncio.run(asyncio.wait_for(verify(args.config), 120))
    except Exception:
        result = {"passed": False, "stage": "connection-or-timeout"}
    print(json.dumps(result))
    raise SystemExit(0 if result["passed"] else 1)


if __name__ == "__main__":
    main()
