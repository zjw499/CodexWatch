from pathlib import Path

import pytest

from verify_watch_voice_metadata import INTENTS, validate_descriptions, validate_metadata


@pytest.mark.parametrize("name", ["Apple Watch", "iPhone"])
def test_rejects_app_store_siri_reserved_description_names(name):
    with pytest.raises(ValueError, match="ITMS-90626"):
        validate_descriptions(f'static let description = IntentDescription("Talk using {name}.")')


def test_normal_device_instructions_are_allowed_outside_siri_descriptions():
    validate_descriptions('Text("Open the iPhone app on your Apple device.")\n'
                          'static let description = IntentDescription("Talk using your Watch microphone and speaker.")')


def test_catalog_requires_current_and_saved_compatibility_actions(tmp_path):
    payload = tmp_path / "actions.json"
    payload.write_text(" ".join(INTENTS), encoding="utf-8")
    validate_metadata(tmp_path)
    payload.write_text(" ".join(name for name in INTENTS if name != "StartWatchRecordingIntent"), encoding="utf-8")
    with pytest.raises(ValueError, match="StartWatchRecordingIntent"):
        validate_metadata(tmp_path)


def test_released_source_passes_siri_description_preflight():
    validate_descriptions((Path(__file__).resolve().parent.parent / "shared/ScribeShortcuts.swift").read_text(encoding="utf-8"))
