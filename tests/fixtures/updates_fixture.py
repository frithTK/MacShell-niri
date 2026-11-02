import json
import sys

action = sys.argv[1]
if action == "status":
    result = {"release": {"state":"available", "installed":"1.1.0", "latest":"1.2.0", "tag":"v1.2.0"},
              "packages": {"state":"available", "count":2, "packages":["alpha 1 -> 2", "beta 3 -> 4"]},
              "prepared": None, "clipboard": True}
elif action == "prepare" and sys.argv[2:] == ["v1.2.0"]:
    result = {"prepared":{"tag":"v1.2.0", "command":"bash /tmp/macshell-demo/install.sh"}}
elif action == "install-packages":
    result = {"launched":True}
else:
    raise SystemExit(1)
print(json.dumps(result))
