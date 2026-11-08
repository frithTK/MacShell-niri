import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
CRATE = ROOT / "native/session-service"


class SessionServiceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        subprocess.run(["cargo", "build", "--offline", "--manifest-path", str(CRATE / "Cargo.toml")], check=True)
        cls.binary = CRATE / "target/debug/macshell-session-service"

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.state = root / "state"
        self.state.mkdir()
        self.compositor = root / "compositor.json"
        self.compositor.write_text(json.dumps({"windows": [{"id": 10, "app_id": "test", "title": "window", "workspace_id": 1, "is_floating": False}], "workspaces": [{"id": 1, "idx": 1, "name": None, "output": "test"}, {"id": 2, "idx": 2, "name": None, "output": "test"}], "outputs": {}, "version": {}}))
        fake = root / "niri"
        fake.write_text('''#!/usr/bin/env python3
import json, os, sys
p = os.environ["FAKE_NIRI"]
with open(p) as f: state = json.load(f)
if sys.argv[1:3] == ["msg", "-j"]:
    print(json.dumps(state[sys.argv[3]]))
elif sys.argv[1:] == ["msg", "raw-request"]:
    action = json.load(sys.stdin)["Action"]
    if os.environ.get("FAKE_REJECT_ACTION"):
        print(json.dumps({"Err": "rejected"}))
        sys.exit(0)
    if not os.environ.get("FAKE_IGNORE_ACTION"):
        for w in state["windows"]:
            if "MoveWindowToWorkspace" in action and w["id"] == action["MoveWindowToWorkspace"]["window_id"]:
                w["workspace_id"] = action["MoveWindowToWorkspace"]["reference"]["Id"]
            if "MoveWindowToFloating" in action and w["id"] == action["MoveWindowToFloating"]["id"]: w["is_floating"] = True
            if "MoveWindowToTiling" in action and w["id"] == action["MoveWindowToTiling"]["id"]: w["is_floating"] = False
        with open(p, "w") as f: json.dump(state, f)
    print(json.dumps({"Ok": "Handled"}))
else: sys.exit(1)
''')
        fake.chmod(0o755)
        self.env = dict(os.environ, PATH=str(root) + os.pathsep + os.environ["PATH"], FAKE_NIRI=str(self.compositor), MACSHELL_SESSION_STATE_HOME=str(self.state))

    def request(self, action):
        process = subprocess.run([str(self.binary)], input=json.dumps({"id": 1, "action": action}) + "\n", text=True, capture_output=True, env=self.env, check=True, timeout=10)
        return json.loads(process.stdout.splitlines()[-1])

    def modify(self, callback):
        data = json.loads(self.compositor.read_text())
        callback(data)
        self.compositor.write_text(json.dumps(data))

    def test_restore_and_verify_workspace_and_floating(self):
        self.assertTrue(self.request("save")["success"])
        self.modify(lambda s: s["windows"][0].update(workspace_id=2, is_floating=True))
        plan = self.request("restore-plan")["result"]
        self.assertEqual(len(plan["windows"][0]["actions"]), 2)
        self.assertTrue(self.request("restore")["result"]["verified"])
        current = json.loads(self.compositor.read_text())["windows"][0]
        self.assertEqual((current["workspace_id"], current["is_floating"]), (1, False))

    def test_action_acknowledged_without_change_fails_verification(self):
        self.request("save")
        self.modify(lambda s: s["windows"][0].update(workspace_id=2))
        self.env["FAKE_IGNORE_ACTION"] = "1"
        response = self.request("restore")
        self.assertFalse(response["success"])
        self.assertIn("verification failed", response["error"])

    def test_rejected_action_is_reported(self):
        self.request("save")
        self.modify(lambda s: s["windows"][0].update(workspace_id=2))
        self.env["FAKE_REJECT_ACTION"] = "1"
        response = self.request("restore")
        self.assertFalse(response["success"])
        self.assertIn("niri rejected action", response["error"])

    def test_skips_ambiguous_and_unavailable_windows(self):
        self.modify(lambda s: s["windows"].append(dict(s["windows"][0], id=11)))
        self.request("save")
        self.modify(lambda s: s["windows"].pop())
        self.assertEqual(len(self.request("restore-plan")["result"]["skipped"]), 2)
        self.modify(lambda s: s["windows"].clear())
        self.assertEqual(len(self.request("restore-plan")["result"]["skipped"]), 2)

    def test_missing_workspace_and_corrupt_snapshot(self):
        self.request("save")
        self.modify(lambda s: s["workspaces"].clear())
        self.assertEqual(self.request("restore-plan")["result"]["skipped"][0]["reason"], "workspace_unavailable")
        (self.state / "current.json").write_text("invalid")
        self.assertFalse(self.request("inspect")["success"])


if __name__ == "__main__":
    unittest.main()
