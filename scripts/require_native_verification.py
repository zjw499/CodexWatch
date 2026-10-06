"""Wait for successful native verification of the app source being distributed."""
import json
import os
import re
import time
import urllib.request


SOURCE_PATHS = {"ios", "watchos", "shared", "native-tests", "native-ui-tests", "server_workspace", "project.yml"}


def source_fingerprint(get, sha):
    commit = get(f"commits/{sha}")
    tree = get(f"git/trees/{commit['commit']['tree']['sha']}")
    source = {entry["path"]: entry["sha"] for entry in tree["tree"] if entry["path"] in SOURCE_PATHS}
    if source.keys() != SOURCE_PATHS:
        raise RuntimeError("Native verification source is incomplete")
    source["native-workflow"] = get(f"contents/.github/workflows/native-verify.yml?ref={sha}")["sha"]
    return source


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
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)

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
        if run["status"] == "completed":
            if run["conclusion"] != "success":
                raise RuntimeError("Native verification did not pass; distribution stopped")
            print("Matching iPhone, Watch, shared, backend and test source verified.", flush=True)
            return
        if time.monotonic() >= deadline:
            raise RuntimeError("Native verification is still pending; distribution stopped")
        time.sleep(20)
        run = get(f"actions/runs/{run_id}")


if __name__ == "__main__":
    main()
