import configparser
import json
import shlex
import sys
from pathlib import Path

mode, path, expected = sys.argv[1:]
expected = json.loads(expected)
if mode == "systemd":
    timer = configparser.ConfigParser(interpolation=None)
    timer.optionxform = str
    timer.read(path)
    service = configparser.ConfigParser(interpolation=None)
    service.optionxform = str
    service.read(str(Path(path).with_suffix(".service")))
    actual = {
        "initial": timer["Timer"]["OnActiveSec"],
        "repeat": timer["Timer"]["OnUnitActiveSec"],
        "target": timer["Install"]["WantedBy"],
        "type": service["Service"]["Type"],
        "exec": shlex.split(service["Service"]["ExecStart"]),
    }
else:
    actual = []
    for line in Path(path).read_text().splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        fields = line.split(maxsplit=5)
        assert len(fields) == 6, line
        command = fields[5].replace(r"\%", "%")
        actual.append({"time": fields[:5], "command": shlex.split(command)})
assert actual == expected, (actual, expected)
