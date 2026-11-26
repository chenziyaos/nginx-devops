"""Read the JSON that ingress2gateway prints (objects one after another, not a list).

  python3 i2g.py summary FILE   # one line per HTTPRoute rule: matches, backends, filters, timeouts
  python3 i2g.py fix FILE       # the HTTPRoute with its two regex paths as PathPrefix /api and /
"""
import json
import sys


def objects(path):
    s, dec, i, out = open(path).read(), json.JSONDecoder(), 0, []
    while True:
        while i < len(s) and s[i].isspace():
            i += 1
        if i == len(s):
            return out
        o, i = dec.raw_decode(s, i)
        out.append(o)


def routes(path):
    return [o for o in objects(path) if o["kind"] == "HTTPRoute"]


def summary(path):
    for o in routes(path):
        for i, r in enumerate(o["spec"]["rules"]):
            m = ", ".join("{} {}".format(x["path"]["type"], x["path"]["value"]) for x in r["matches"])
            # sorted: the order of the backends differs from run to run
            b = ", ".join(sorted("{} {}".format(x["name"], x.get("weight", "")).strip() for x in r["backendRefs"]))
            f = ", ".join(x["type"] for x in r.get("filters", [])) or "-"
            t = r.get("timeouts", {}).get("request", "-")
            print("rule {}: match {}; backends {}; filters {}; timeouts.request {}".format(i, m, b, f, t))


def fix(path):
    for o in routes(path):
        for r in o["spec"]["rules"]:
            prefix = "/api" if "/api" in r["matches"][0]["path"]["value"] else "/"
            r["matches"] = [{"path": {"type": "PathPrefix", "value": prefix}}]
        o.pop("status", None)
        print(json.dumps(o))


{"summary": summary, "fix": fix}[sys.argv[1]](sys.argv[2])
