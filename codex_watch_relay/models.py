from __future__ import annotations

from datetime import datetime

from pydantic import BaseModel, ConfigDict, Field, field_validator


class DesktopTarget(BaseModel):
    model_config = ConfigDict(extra="forbid")

    id: str
    name: str
    platform: str
    online: bool
    has_d_drive: bool
    relay_state: str


class WatchThreadSummary(BaseModel):
    model_config = ConfigDict(extra="forbid")

    id: str
    name: str
    preview: str
    cwd: str | None
    updated_at: int
    status: str
    unread_reply: bool = False
    plan_mode_enabled: bool = False


class WatchThreadDetail(BaseModel):
    model_config = ConfigDict(extra="forbid")

    id: str
    name: str
    preview: str
    cwd: str | None
    updated_at: int
    status: str
    latest_reply: str | None = None
    latest_snippet: str | None = None
    changed_files_count: int = 0
    recent_tool_summary: str | None = None
    unread_reply: bool = False
    plan_mode_enabled: bool = False


class WatchTurnState(BaseModel):
    model_config = ConfigDict(extra="forbid")

    turn_id: str
    thread_id: str
    status: str
    snippet: str | None = None
    latest_message: str | None = None
    pending_questionnaire_id: str | None = None
    error_message: str | None = None


class WorkingFolderNode(BaseModel):
    model_config = ConfigDict(extra="forbid")

    token: str
    absolute_path: str
    display_name: str
    parent_label: str | None = None
    is_pinned: bool = False
    is_recent: bool = False


class WatchOption(BaseModel):
    model_config = ConfigDict(extra="forbid")

    label: str
    description: str


class WatchQuestion(BaseModel):
    model_config = ConfigDict(extra="forbid")

    id: str
    header: str
    question: str
    options: list[WatchOption] = Field(default_factory=list)
    supports_other_voice: bool = False


class WatchQuestionnaire(BaseModel):
    model_config = ConfigDict(extra="forbid")

    request_id: str
    item_id: str
    thread_id: str
    turn_id: str
    questions: list[WatchQuestion]
    created_at: datetime
    answered: bool = False


class InboxNotification(BaseModel):
    model_config = ConfigDict(extra="forbid")

    id: str
    type: str
    desktop_id: str
    thread_id: str
    turn_id: str | None = None
    summary: str
    status: str
    deep_link: str
    created_at: datetime
    read: bool = False


class ThreadCreateRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    cwd: str | None = None
    plan_mode: bool = False
    prompt: str | None = None

    @field_validator("prompt")
    @classmethod
    def validate_prompt(cls, value: str | None) -> str | None:
        if value is None:
            return None
        stripped = value.strip()
        return stripped or None


class TurnSubmissionRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    prompt: str = Field(min_length=1, max_length=8000)
    cwd: str | None = None
    plan_mode: bool = False

    @field_validator("prompt")
    @classmethod
    def validate_prompt(cls, value: str) -> str:
        stripped = value.strip()
        if not stripped:
            raise ValueError("prompt must not be blank")
        return stripped


class QuestionnaireAnswerValue(BaseModel):
    model_config = ConfigDict(extra="forbid")

    answers: list[str]


class QuestionnaireAnswerRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    answers: dict[str, QuestionnaireAnswerValue]


class FavoriteFolderRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    path: str


class FolderListResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    entries: list[WorkingFolderNode]


class ThreadStartEnvelope(BaseModel):
    model_config = ConfigDict(extra="forbid")

    thread: WatchThreadSummary
    turn: WatchTurnState | None = None


class ThreadListResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    data: list[WatchThreadSummary]


class QuestionnaireListResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    data: list[WatchQuestionnaire]


class InboxListResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    data: list[InboxNotification]


class HealthResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    ok: bool
    service: str
    desktop_online: bool
    version: str
