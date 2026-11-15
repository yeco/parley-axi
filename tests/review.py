"""CLI regressions: unread ownership and scheduler safety from the agreed design.

The independent oracle is the author's unread/scheduling contract. These cases
reject writer-dependent delivery, self-wakes, lost post-print activity, cron
replacement on read failure, and cadence-only checks with a wrong executable.
"""
from datetime import datetime, timedelta
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

ROOT = Path(__file__).absolute().parent.parent
with tempfile.TemporaryDirectory(prefix="parley-review-") as tmp:
    tmp = Path(tmp)
    stub = tmp / "gh"
    stub.mkdir()
    env = {
        **os.environ,
        "HOME": str(tmp / "home"),
        "XDG_CONFIG_HOME": str(tmp / "config"),
        "XDG_STATE_HOME": str(tmp / "state"),
        "STUB_DIR": str(stub),
        "STUB_LOG": str(tmp / "calls"),
        "PATH": f"{ROOT / 'tests/stub'}:{os.environ['PATH']}",
        "PARLEY_AXI": str(ROOT / "bin/parley-axi"),
        "PARLEY_INTERVAL": "0",
    }
    for key in ("PARLEY_INBOX", "PARLEY_CRASH_AT", "STUB_GH_FAIL", "STUB_SYSTEMCTL",
                "STUB_READ_RACE", "STUB_CRON_READ_FAIL", "STUB_RACE_ACTOR", "STUB_TOUCH_LABELS", "STUB_EDIT_FAIL", "STUB_SAME_SECOND", "STUB_CRON_HOLD"):
        env.pop(key, None)
    (tmp / "home").mkdir()
    config = tmp / "config/parley-axi/config.json"
    config.parent.mkdir(parents=True)
    config.write_text(json.dumps({"default": "team", "inboxes": {
        "team": {"repo": "acme/team", "member": "alice"},
        "other": {"repo": "acme/team", "member": "alice"},
    }}))
    (stub / "acme__team.parley.json").write_text(json.dumps({"members": [
        {"id": "alice", "github": "alice-gh"}, {"id": "bob", "github": "bob-gh"},
    ]}))
    (stub / "acme__team.labels").write_text("")
    file = stub / "acme__team.issue-1.json"

    def save(data):
        file.write_text(json.dumps(data))
        (stub / "acme__team.issues.json").write_text(json.dumps([{
            "number": 1, "title": data["title"], "body": data["body"], "state": data["state"].lower(),
            "comments": len(data["comments"]), "labels": data["labels"],
            "created_at": data["createdAt"], "updated_at": data["updatedAt"],
            "html_url": data["url"],
        }]))

    def fixture(sender="bob", state="OPEN", status="open"):
        save({"id": "thread-1", "number": 1, "title": "Review request", "body": "Old body",
              "author": {"login": sender + "-gh"}, "state": state,
              "createdAt": "2026-11-05T10:00:00Z", "updatedAt": "2026-11-05T10:00:00Z",
              "url": "https://x/1", "comments": [], "edits": [], "timeline": [],
              "labels": [{"name": "from:" + sender},
                         {"name": "to:" + ("alice" if sender == "bob" else "bob")},
                         {"name": "status:" + status}]})
        for member in ("alice", "bob"):
            for name in ("read", "activity", "state", "pending"):
                (tmp / f"state/parley-axi/team/{member}/acme:team/{name}.json").unlink(missing_ok=True)

    def call(*args, member="alice", extra=None, ok=True):
        result = subprocess.run([str(ROOT / "bin/parley-axi"), "--as", member, *args],
                                env={**env, "STUB_LOGIN": member + "-gh", **(extra or {})},
                                text=True, capture_output=True)
        assert (result.returncode == 0) == ok, (args, result.returncode, result.stderr)
        return result.stdout

    def unread(member="alice"):
        call("sync", "--no-commit", "--json", member=member)
        return [item["number"] for item in json.loads(call("list", "--unread", "--json", member=member))]

    def mutate(expression, advance=True):
        data = json.loads(file.read_text())
        expression(data)
        if advance:
            data["updatedAt"] = (datetime.fromisoformat(data["updatedAt"].replace("Z", "+00:00")) + timedelta(seconds=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
        save(data)

    fixture()
    assert unread() == [1]
    call("show", "1")
    assert unread() == []
    call("reply", "1", "Plain reply", member="bob")
    assert unread() == [1], file.read_text()
    assert unread("bob") == []
    call("show", "1", "--json")
    assert unread() == []
    call("reply", "1", "My own reply")
    assert unread() == []
    assert unread("bob") == [1]
    call("show", "1", member="bob")
    assert unread("bob") == []
    print("ok reader-owned receipts, replies in both directions, own activity")

    for sender in ("alice", "bob"):
        for state, status in (("OPEN", "open"), ("CLOSED", "done")):
            fixture(sender, state, status)
            call("show", "1")
            mutate(lambda d: d["comments"].append({
                "id": "github-comment", "body": "GitHub reply", "author": {"login": "bob-gh"},
                "createdAt": "2026-11-05T11:00:00Z", "edits": [],
            }))
            assert unread() == [1], (sender, state)
            call("show", "1")
            mutate(lambda d: (d["comments"][0].update(body="Edited through GitHub"),
                              d["comments"][0]["edits"].append({"id": "comment-edit", "editor": {"login": "bob-gh"}})))
            assert unread() == [1]
            call("show", "1")
            mutate(lambda d: (d.update(body="Edited body"),
                              d["edits"].append({"id": "body-edit", "editor": {"login": "bob-gh"}})))
            assert unread() == [1]
            call("show", "1")
            assert unread() == []
    print("ok GitHub comments and edits on incoming/sent, open/closed threads")

    for event in ("RenamedTitleEvent", "ClosedEvent", "ReopenedEvent", "LabeledEvent", "UnlabeledEvent"):
        fixture()
        call("show", "1")
        mutate(lambda d: d["timeline"].append({"id": event, "__typename": event,
                                               "actor": {"login": "bob-gh"},
                                               **({"label": {"name": "status:done"}} if "labeled" in event.lower() else {})}))
        assert unread() == [1], event
        call("show", "1")
        assert unread() == []
    fixture()
    call("show", "1")
    mutate(lambda d: d["timeline"].append({"id": "projection", "__typename": "LabeledEvent",
                                          "actor": {"login": "bob-gh"}, "label": {"name": "unread:bob"}}))
    assert unread() == []
    print("ok title/lifecycle/status activity; unread projection does not self-wake")

    for command, state, status, member in (("ack", "OPEN", "open", "alice"),
                                            ("done", "OPEN", "open", "bob"),
                                            ("decline", "OPEN", "open", "alice"),
                                            ("reopen", "CLOSED", "done", "bob")):
        fixture("bob", state, status)
        call("show", "1")
        call("show", "1", member="bob")
        args = (command, "1") if command == "ack" else (command, "1", "Reason")
        call(*args, member=member)
        other = "bob" if member == "alice" else "alice"
        assert unread(member) == []
        assert unread(other) == [1]
    print("ok all transition callers publish activity without setting reader markers")

    for actor, expected in (("bob-gh", [1]), ("alice-gh", [])):
        fixture()
        assert unread() == [1]
        printed = call("show", "1", extra={"STUB_READ_RACE": "1", "STUB_RACE_ACTOR": actor})
        assert "A concurrent update" not in printed
        assert unread() == expected
    fixture()
    call("show", "1")
    mutate(lambda d: d["comments"].append({"id": "writer-crash", "body": "Landed after show",
                                          "createdAt": "2026-11-05T12:00:00Z", "author": {"login": "bob-gh"}}))
    assert unread() == [1]
    before = (tmp / "state/parley-axi/team/alice/acme:team/read.json").read_bytes()
    for mode in ((), ("--json",)):
        failed = subprocess.run(["bash", str(ROOT / "bin/parley-axi"), "show", "1", *mode], env=env,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                preexec_fn=lambda: os.close(1))
        assert failed.returncode != 0
        assert (tmp / "state/parley-axi/team/alice/acme:team/read.json").read_bytes() == before
    result = subprocess.Popen([str(ROOT / "bin/parley-axi"), "show", "1"], env=env,
                              stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    result.stdout.close()
    assert result.wait() != 0
    assert (tmp / "state/parley-axi/team/alice/acme:team/read.json").read_bytes() == before
    print("ok concurrent incoming activity survives; concurrent own activity stays read")

    fixture()
    call("show", "1")
    stale = json.loads(file.read_text())
    mutate(lambda d: d["comments"].append({"id": "known-new", "body": "Unseen newer content",
                                          "author": {"login": "bob-gh"}, "createdAt": "2026-11-05T12:00:00Z"}))
    assert unread() == [1]
    latest = json.loads(file.read_text())
    save(stale)
    assert "Unseen newer content" not in call("show", "1")
    assert [item["number"] for item in json.loads(call("list", "--unread", "--json"))] == [1]
    save(latest)
    call("show", "1")
    assert unread() == []
    print("ok stale show cannot discard known unread activity or cached versions")

    for mode in ((), ("--json",)):
        fixture()
        assert unread() == [1]
        displayed = call("show", "1", *mode, extra={"STUB_EDIT_FAIL": "1"}, ok=False)
        assert "Old body" in displayed
        assert [item["number"] for item in json.loads(call("list", "--unread", "--json"))] == []
        assert "unread:alice" in [label["name"] for label in json.loads(file.read_text())["labels"]]
        Path(env["STUB_LOG"]).write_text("")
        call("sync", "--json")
        assert "unread:alice" not in [label["name"] for label in json.loads(file.read_text())["labels"]]
        assert not any(line.startswith("api graphql") for line in Path(env["STUB_LOG"]).read_text().splitlines())
    fixture()
    call("sync", "--json", extra={"STUB_EDIT_FAIL": "1"}, ok=False)
    assert [item["number"] for item in json.loads(call("list", "--unread", "--json"))] == [1]
    Path(env["STUB_LOG"]).write_text("")
    assert [(item["number"], item["event"]) for item in json.loads(call("sync", "--json"))] == [(1, "new")]
    assert not any(line.startswith("api graphql") for line in Path(env["STUB_LOG"]).read_text().splitlines())
    print("ok receipts control cached unread despite failed projection; sync retries publication without history scans")

    fixture()
    call("sync", "--json")
    call("show", "1")
    call("reply", "1", "Same-second incoming reply", member="bob", extra={"STUB_SAME_SECOND": "1"})
    problems = json.loads(call("sync", "--verify", "--json", ok=False))["problems"]
    assert any("#1 update not surfaced" in problem for problem in problems)
    delivered = json.loads(call("sync", "--json"))
    assert [(item["number"], item["event"]) for item in delivered] == [(1, "updated")]
    assert [item["number"] for item in json.loads(call("list", "--unread", "--json"))] == [1]
    assert json.loads(call("sync", "--json")) == []
    call("show", "1")
    call("reply", "1", "Same-second own reply", extra={"STUB_SAME_SECOND": "1"})
    assert unread() == []
    for field in ("title", "body", "state", "status"):
        fixture()
        call("show", "1")
        def edit(data):
            event = {"id": "same-second-" + field, "actor": {"login": "bob-gh"}}
            if field == "title":
                data["title"] = "Renamed request"
                data["timeline"].append({**event, "__typename": "RenamedTitleEvent"})
            elif field == "body":
                data["body"] = "Edited body in the same second"
                data["edits"].append({"id": event["id"], "editor": event["actor"]})
            elif field == "state":
                data["state"] = "CLOSED"
                data["timeline"].append({**event, "__typename": "ClosedEvent"})
            else:
                data["labels"] = [label for label in data["labels"] if not label["name"].startswith("status:")]
                data["labels"].append({"name": "status:acknowledged"})
                data["timeline"].append({**event, "__typename": "LabeledEvent", "label": {"name": "status:acknowledged"}})
        mutate(edit, advance=False)
        assert unread() == [1], field
        call("show", "1")
        assert unread() == []
    print("ok same-second comments, title/body edits, state/status changes and delivery verification")

    for sender, prefix in (("bob", "to:"), ("alice", "from:")):
        fixture(sender=sender)
        if sender == "alice":
            call("reply", "1", "Incoming on a sent thread", member="bob")
        assert unread() == [1]
        original = json.loads(file.read_text())
        mutate(lambda d: d.update(labels=[{"name": prefix + "carol"} if label["name"].startswith(prefix) else label
                                         for label in d["labels"]]), advance=False)
        assert unread() == []
        call("show", "1", ok=False)
        assert "unread:alice" not in [label["name"] for label in json.loads(file.read_text())["labels"]]
        result = subprocess.run(["bash", str(ROOT / "checks/parley.check.sh")], env=env,
                                text=True, capture_output=True, check=True)
        assert result.stdout == ""
        save(original)
        assert unread() == [1]
    print("ok raw same-second sender/recipient retargeting revokes cached participation and read access")

    fixture()
    long_body = "x" * 50_000
    mutate(lambda d: d["comments"].extend([
        {"id": f"long-{i}", "body": long_body, "author": {"login": "bob-gh"},
         "createdAt": "2026-11-05T11:00:00Z", "edits": []} for i in range(3)
    ]))
    assert unread() == [1]
    shown = json.loads(call("show", "1", "--json"))
    assert [c["body"] for c in shown["comments"]] == [long_body] * 3
    assert unread() == []
    unicode_body = "🌴" * 50_000
    mutate(lambda d: (d.update(body=unicode_body), d["comments"][0].update(body=unicode_body),
                      d["comments"][0]["edits"].append({"id": "unicode-edit", "editor": {"login": "bob-gh"}})))
    shown = json.loads(call("show", "1", "--json"))
    assert shown["body"] == unicode_body and shown["comments"][0]["body"] == unicode_body
    assert unread() == []
    mutate(lambda d: d["edits"].extend([
        {"id": f"edit-{i}-" + "e" * 64, "editor": {"login": "bob-gh"}} for i in range(2_000)
    ]))
    assert unread() == [1]
    call("show", "1", "--json")
    assert unread() == []
    print("ok long comment collections and activity receipts use stream transport")

    fixture()
    data = json.loads(file.read_text())
    second = {**data, "number": 2, "id": "thread-2", "title": "Second request", "url": "https://x/2"}
    (stub / "acme__team.issue-2.json").write_text(json.dumps(second))
    listing = json.loads((stub / "acme__team.issues.json").read_text())
    listing.append({**listing[0], "number": 2, "title": "Second request", "html_url": "https://x/2"})
    (stub / "acme__team.issues.json").write_text(json.dumps(listing))
    lock = tmp / "state/parley-axi/team/alice/acme:team/state.lock"
    lock.parent.mkdir(parents=True, exist_ok=True)
    import fcntl
    with lock.open("w") as held:
        fcntl.flock(held, fcntl.LOCK_EX)
        readers = [subprocess.Popen([str(ROOT / "bin/parley-axi"), "show", str(n), *mode],
                                    env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                   for n, mode in ((1, ()), (2, ("--json",)))]
        headers = [reader.stdout.readline() for reader in readers]
        assert "Review request" in headers[0] and "Second request" in headers[1]
        assert all(reader.poll() is None for reader in readers)
        fcntl.flock(held, fcntl.LOCK_UN)
    for reader in readers:
        stdout, stderr = reader.communicate(timeout=30)
        assert reader.returncode == 0, stderr
    assert unread() == []
    receipts = json.loads((lock.parent / "read.json").read_text())
    assert receipts["1"] == ["thread-1"] and receipts["2"] == ["thread-2"]
    (stub / "acme__team.issue-2.json").unlink()
    fixture()
    call("show", "1")
    mutate(lambda d: d["comments"].append({"id": "scheduler-new", "body": "Notify",
                                          "createdAt": "2026-11-05T12:00:00Z", "author": {"login": "bob-gh"}}))
    assert unread() == [1]
    print("ok simultaneous text/JSON shows preserve both receipts")

    runner = tmp / "state/parley-axi/schedule/team/alice/tick.sh"
    notification = tmp / "notification"
    call("schedule", "install", "--every", "5m", "--notify", f"cat > '{notification}'",
         extra={"STUB_SYSTEMCTL": "1"})
    timer = tmp / "config/systemd/user/parley-axi-team:alice.timer"
    systemd_expected = {"initial": "300s", "repeat": "300s", "target": "timers.target",
                        "type": "oneshot", "exec": ["/bin/bash", str(runner)]}
    subprocess.run(["python3", str(ROOT / "tests/schedule_contract.py"), "systemd", str(timer),
                    json.dumps(systemd_expected)], check=True)
    call("schedule", "tick")
    assert notification.read_text() == "#1 unread from bob: Review request\n"
    notification.unlink()
    call("show", "1")
    assert call("schedule", "tick") == ""
    assert not notification.exists()
    mutate(lambda d: d["comments"].append({"id": "check-comment", "body": "Check me",
                                          "createdAt": "2026-11-05T12:00:00Z", "author": {"login": "bob-gh"}}))
    result = subprocess.run(["bash", str(ROOT / "checks/parley.check.sh")], env=env,
                            text=True, capture_output=True, check=True)
    assert "1 unread message(s): #1 unread from bob: Review request" in result.stdout
    call("schedule", "remove", extra={"STUB_SYSTEMCTL": "1"})
    print("ok heartbeat stdin, silent read tick, and check share unread computation")

    fixture()
    call("sync", "--json")
    Path(env["STUB_LOG"]).write_text("")
    call("schedule", "install", "--every", "5m", "--notify", "true", extra={"STUB_SYSTEMCTL": "1"})
    Path(env["STUB_LOG"]).write_text("")
    call("schedule", "tick")
    requests = Path(env["STUB_LOG"]).read_text().splitlines()
    assert sum(line.startswith("api --paginate repos/acme/team/issues?") for line in requests) == 1
    assert not any(line.startswith("api graphql") or line.startswith("issue ") for line in requests)
    call("schedule", "remove", extra={"STUB_SYSTEMCTL": "1"})
    fixture(sender="alice")
    call("sync", "--json")
    Path(env["STUB_LOG"]).write_text("")
    call("sync", "--json")
    requests = Path(env["STUB_LOG"]).read_text().splitlines()
    assert sum(line.startswith("api --paginate repos/acme/team/issues?") for line in requests) == 1
    assert any("since=2026-11-05T09:50:00Z" in line for line in requests)
    assert not any(line.startswith("api graphql") for line in requests)
    print("ok unchanged heartbeat costs one list request; sent-only inboxes retain an incremental cursor")

    for step in ("write-pending", "emit", "commit", "swap"):
        fixture()
        failed = subprocess.run([str(ROOT / "bin/parley-axi"), "sync", "--json"],
                                env={**env, "PARLEY_CRASH_AT": step}, text=True, capture_output=True)
        assert failed.returncode == 70, (step, failed.stderr)
        recovered = json.loads(call("sync", "--json"))
        assert [(item["number"], item["event"]) for item in recovered] == [(1, "new")]
        assert json.loads(call("sync", "--json")) == []
    print("ok incremental cache preserves at-least-once delivery across every sync crash point")

    repo_config = stub / "acme__team.parley.json"
    original_config = repo_config.read_text()
    roles = ("to", "from", "status", "unread")
    for shorter in roles:
        for longer in roles:
            if shorter == longer:
                continue
            candidate = json.loads(original_config)
            candidate["labels"] = {role: role + ":" for role in roles}
            candidate["labels"][shorter] = "u"
            candidate["labels"][longer] = "unread:"
            repo_config.write_text(json.dumps(candidate))
            Path(env["STUB_LOG"]).write_text("")
            call("sync", ok=False)
            assert not any(line.startswith(("issue edit", "label create"))
                           for line in Path(env["STUB_LOG"]).read_text().splitlines())
    repo_config.write_text(original_config)
    print("ok every ordered prefix-overlap pair is rejected before publishing labels")

    fixture()
    assert unread() == [1]
    call("init", "--repo", "acme/team", "--direct")
    replacement = json.loads(file.read_text())
    replacement.update(id="replacement-thread-1", title="Replacement request", body="Replacement body",
                       createdAt="2025-01-01T00:00:00Z", updatedAt="2025-01-01T00:00:00Z", url="https://replacement/1")
    replacement["labels"] = [label for label in replacement["labels"] if not label["name"].startswith("unread:")]
    (stub / "acme__replacement.parley.json").write_text(original_config)
    (stub / "acme__replacement.issue-1.json").write_text(json.dumps(replacement))
    (stub / "acme__replacement.issues.json").write_text(json.dumps([{
        "number": 1, "title": replacement["title"], "body": replacement["body"], "state": "open", "comments": 0,
        "labels": replacement["labels"], "created_at": replacement["createdAt"], "updated_at": replacement["updatedAt"],
        "html_url": replacement["url"],
    }]))
    call("init", "--repo", "acme/replacement", "--direct")
    call("setup", "--repo", "acme/replacement", "--name", "team", "--default")
    assert json.loads(call("list", "--unread", "--json")) == []
    replacement_events = json.loads(call("sync", "--json"))
    assert [(item["number"], item["subject"], item["url"]) for item in replacement_events] == [(1, "Replacement request", "https://replacement/1")]
    scoped_notification = tmp / "scoped-notification"
    call("schedule", "install", "--every", "5m", "--notify", f"cat > '{scoped_notification}'", extra={"STUB_SYSTEMCTL": "1"})
    call("schedule", "tick")
    assert scoped_notification.read_text() == "#1 unread from bob: Replacement request\n"
    call("schedule", "remove", extra={"STUB_SYSTEMCTL": "1"})
    assert "Replacement body" in call("show", "1")
    assert unread() == []
    call("setup", "--repo", "acme/team", "--name", "team", "--default")
    restored = json.loads(call("list", "--unread", "--json"))
    assert [(item["subject"], item["url"]) for item in restored] == [("Review request", "https://x/1")]
    print("ok alias reassignment isolates receipts, cached messages, delivery and heartbeat by repository")

    cron = stub / "crontab"
    cron.write_text("17 * * * * echo unrelated-job\n")
    unrelated = {"time": ["17", "*", "*", "*", "*"], "command": ["echo", "unrelated-job"]}

    def entry(time, inbox="team", member="alice"):
        return {"time": time.split(), "command": ["/bin/bash", str(tmp / f"state/parley-axi/schedule/{inbox}/{member}/tick.sh"),
                                                    ">/dev/null", "2>&1", "#", f"parley-axi:{inbox}:{member}"]}

    def cron_contract(expected):
        subprocess.run(["python3", str(ROOT / "tests/schedule_contract.py"), "cron", str(cron),
                        json.dumps(expected)], check=True)

    call("schedule", "install", "--every", "5m", "--notify", "true",
         extra={"STUB_CRON_READ_FAIL": "1"}, ok=False)
    cron_contract([unrelated])
    call("schedule", "install", "--every", "5m", "--notify", "true")
    cron_contract([unrelated, entry("*/5 * * * *")])
    before = cron.read_bytes()
    for args in (("schedule", "remove"), ("schedule", "install", "--every", "10m", "--notify", "true")):
        call(*args, extra={"STUB_CRON_READ_FAIL": "1"}, ok=False)
        assert cron.read_bytes() == before
    call("schedule", "install", "--every", "10m", "--notify", "true")
    call("--inbox", "other", "schedule", "install", "--every", "1h", "--notify", "true")
    cron_contract([unrelated, entry("*/10 * * * *"), entry("0 */1 * * *", "other")])
    call("schedule", "remove")
    cron_contract([unrelated, entry("0 */1 * * *", "other")])
    call("--inbox", "other", "schedule", "remove")
    cron_contract([unrelated])
    for interval in ("300", "0", "7m", "30s"):
        call("schedule", "install", "--every", interval, "--notify", "true", ok=False)
        cron_contract([unrelated])
    print("ok cron read failures preserve all jobs; semantic cadence/replacement/removal contracts")

    def wait_for(condition):
        deadline = time.monotonic() + 15
        while not condition():
            assert time.monotonic() < deadline, "scheduler boundary did not become ready"
            time.sleep(0.02)

    def concurrent_schedules(first_args, second_args, expected):
        for name in ("read-first", "read-second", "release-first", "release-second"):
            (stub / name).unlink(missing_ok=True)
        first = subprocess.Popen([str(ROOT / "bin/parley-axi"), *first_args],
                                 env={**env, "STUB_CRON_HOLD": "first"}, text=True,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        wait_for(lambda: (stub / "read-first").exists())
        Path(env["STUB_LOG"]).write_text("")
        second = subprocess.Popen([str(ROOT / "bin/parley-axi"), *second_args],
                                  env={**env, "STUB_CRON_HOLD": "second"}, text=True,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            wait_for(lambda: "contents/.parley.json" in Path(env["STUB_LOG"]).read_text())
            time.sleep(0.3)
            assert not (stub / "read-second").exists()
            (stub / "release-first").touch()
            wait_for(lambda: (stub / "read-second").exists())
            (stub / "release-second").touch()
            for child in (first, second):
                stdout, stderr = child.communicate(timeout=30)
                assert child.returncode == 0, stderr
            cron_contract(expected)
        finally:
            for name in ("release-first", "release-second"):
                (stub / name).touch()
            for child in (first, second):
                if child.poll() is None:
                    child.terminate()
                child.communicate(timeout=30)

    concurrent_schedules(("schedule", "install", "--every", "5m", "--notify", "true"),
                         ("--inbox", "other", "--as", "bob", "schedule", "install", "--every", "1h", "--notify", "true"),
                         [unrelated, entry("*/5 * * * *"), entry("0 */1 * * *", "other", "bob")])
    concurrent_schedules(("schedule", "remove"),
                         ("--inbox", "other", "--as", "bob", "schedule", "install", "--every", "10m", "--notify", "true"),
                         [unrelated, entry("*/10 * * * *", "other", "bob")])
    call("--inbox", "other", "--as", "bob", "schedule", "remove")
    cron_contract([unrelated])
    print("ok concurrent installs and remove/reinstall preserve schedules across inboxes and members")
