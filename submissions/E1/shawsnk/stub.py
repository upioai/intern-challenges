"""接口空桩：只验证评测链路能跑通，不做任何检索。得分预期为 0。"""
import json, sys

cmd = sys.argv[1] if len(sys.argv) > 1 else ""
if cmd == "index":
    print("stub: nothing indexed", file=sys.stderr)
    sys.exit(0)
if cmd == "search":
    print(json.dumps({"route": "index", "results": [], "note": "stub"}, ensure_ascii=False))
    sys.exit(0)
print("usage: index | search <query> [--k N]", file=sys.stderr)
sys.exit(2)
