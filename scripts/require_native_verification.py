"""Wait for successful native verification of the app source being distributed."""
import json
import os
import re
import time
import urllib.error
import urllib.request


SOURCE_PATHS = {"ios", "watchos", "shared", "native-tests", "native-ui-tests", "server_workspace", "project.yml"}
REQUIRED_STEPS = {"Verify workspace isolation and durable jobs", "Build phone and Watch and run queue tests"}


def read_json(request, *, opener=None, sleep=None):
    opener = opener or urllib.request.urlopen
    sleep = sleep or time.sleep
    for attempt in range(5):
        try:
            with opener(request, timeout=30) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            if error.code != 429 and error.code < 500:
                raise
            if attempt == 4:
                raise
        except (urllib.error.URLError, TimeoutError, ConnectionError, json.JSONDecodeError):
            if attempt == 4:
                raise
        print(f"GitHub verification request temporarily unavailable; retrying ({attempt + 1}/5).", flush=True)
        sleep(2 ** (attempt + 1))


def source_fingerprint(get, sha):
    commit = get(f"commits/{sha}")
    tree = get(f"git/trees/{commit['commit']['tree']['sha']}")
    source = {entry["path"]: entry["sha"] for entry in tree["tree"] if entry["path"] in SOURCE_PATHS}
    if source.keys() != SOURCE_PATHS:
        raise RuntimeError("Native verification source is incomplete")
    source["native-workflow"] = get(f"contents/.github/workflows/native-verify.yml?ref={sha}")["sha"]
    return source


def required_checks_passed(get, run_id):
    jobs = get(f"actions/runs/{run_id}/jobs")["jobs"]
    native = [job for job in jobs if job["name"] == "native"]
    if len(native) != 1:
        return False
    checks = {step["name"]: step for step in native[0]["steps"] if step["name"] in REQUIRED_STEPS}
    for step in checks.values():
        if step.get("conclusion") in {"failure", "cancelled", "timed_out", "skipped"}:
            raise RuntimeError("A required native check did not pass; distribution stopped")
    return checks.keys() == REQUIRED_STEPS and all(
        step["status"] == "completed" and step.get("conclusion") == "success" for step in checks.values())


def main():
    evidence = os.environ.get("NATIVE_VERIFICATION_RUN", "")
    match = re.search(r"native-verification-run=(\d+)", evidence)
    run_id = evidence if evidence.isdecimal() else (match.group(1) if match else "")
    if not run_id:
        raise RuntimeError("Distribution requires a native verification run ID")
    repo = os.environ["GITHUB_REPOSITORY"]
    token = os.environ["GH_TOKEN"]

    def get(path):
        request = urllib.request.Request(f"https://api.github.com/repos/{repo}/{path}", headers={
            "Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28"})
        return read_json(request)

    run = get(f"actions/runs/{run_id}")
    if run["name"] != "Verify Scribe Pilot phone and Watch":
        raise RuntimeError("Select the native verification workflow run")
    if source_fingerprint(get, os.environ["GITHUB_SHA"]) != source_fingerprint(get, run["head_sha"]):
        raise RuntimeError("Native verification covers different app source")
    deadline = time.monotonic() + 45 * 60
    last_status = None
    while True:
        status = (run["status"], run["conclusion"])
        if status != last_status:
            print(f"Native verification {run_id}: {status[0]} / {status[1]}", flush=True)
            last_status = status
        checks_passed = required_checks_passed(get, run_id)
        # Signed archive validation separately proves Watch intents and complications.
        # An authorized pilot needs build/tests; simulator preview/export is supplemental.
        if os.environ.get("PILOT_RELEASE") == "true" and checks_passed:
            print("Matching native build and backend/unit/UI tests passed for pilot distribution.", flush=True)
            if run["status"] != "completed" or run["conclusion"] != "success":
                print("Supplemental simulator preview/artifact completion is unverified; physical acceptance remains pending.", flush=True)
            return
        if run["status"] == "completed":
            if run["conclusion"] != "success" or not checks_passed:
                raise RuntimeError("Native verification did not pass; distribution stopped")
            print("Matching iPhone, Watch, shared, backend and test source verified.", flush=True)
            return
        if time.monotonic() >= deadline:
            raise RuntimeError("Native verification is still pending; distribution stopped")
        time.sleep(20)
        run = get(f"actions/runs/{run_id}")


if __name__ == "__main__":
    main()
