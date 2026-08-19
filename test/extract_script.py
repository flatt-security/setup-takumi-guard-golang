"""Print the shell body of action.yml's auth step.

The retry tests execute this body directly instead of going through `uses: ./`
so that stderr (where the retry warnings go) can be asserted on. Extracting it
from action.yml keeps action.yml the single source of truth — a copy of the
script in the test tree would drift.
"""

import sys

import yaml

action = yaml.safe_load(open(sys.argv[1] if len(sys.argv) > 1 else "action.yml"))
for step in action["runs"]["steps"]:
    if step.get("id") == "auth":
        sys.stdout.write(step["run"])
        break
else:
    raise SystemExit("no step with id 'auth' in action.yml")
