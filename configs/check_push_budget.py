"""Check elapsed time since GitHub created the push run, including its queue."""

import json
import os
from datetime import datetime, timezone
from urllib.request import Request, urlopen


def main():
    repo = os.environ["GITHUB_REPOSITORY"]
    run_id = os.environ["GITHUB_RUN_ID"]
    url = f"{os.environ['GITHUB_API_URL']}/repos/{repo}/actions/runs/{run_id}"
    request = Request(url, headers={"Authorization": f"Bearer {os.environ['GH_TOKEN']}"})
    with urlopen(request, timeout=10) as response:
        run = json.load(response)
    if str(run["id"]) != run_id or run["head_sha"] != os.environ["GITHUB_SHA"]:
        raise SystemExit("Workflow run identity does not match the checked-out push")
    created = datetime.fromisoformat(run["created_at"].replace("Z", "+00:00"))
    elapsed = (datetime.now(timezone.utc) - created).total_seconds()
    print(f"Push run {run_id}: {elapsed:.1f} seconds including queue and cold build (limit 300).")
    if elapsed > 300:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
