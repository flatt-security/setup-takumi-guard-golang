"""Print the shell body of one step of action.yml (the auth step by default).

Usage: extract_script.py [action.yml] [step-id]

The tests execute this body directly instead of going through `uses: ./` so
that stderr (where the retry warnings go) and the files the step writes can be
asserted on. Extracting it from action.yml keeps action.yml the single source
of truth — a copy of the script in the test tree would drift.
"""

import sys

import yaml

path = sys.argv[1] if len(sys.argv) > 1 else "action.yml"
step_id = sys.argv[2] if len(sys.argv) > 2 else "auth"

action = yaml.safe_load(open(path))
for step in action["runs"]["steps"]:
    if step.get("id") == step_id:
        sys.stdout.write(step["run"])
        break
else:
    raise SystemExit(f"no step with id '{step_id}' in action.yml")
