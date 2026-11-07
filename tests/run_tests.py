"""Runs the Lua unit tests and syntax-checks every mod script. Needs: pip install lupa"""
import sys, pathlib
from lupa import LuaRuntime
root = pathlib.Path(__file__).resolve().parent.parent
scripts = root / "TS2TPSCamera" / "Scripts"
lua = LuaRuntime(unpack_returned_tuples=True)
bad = 0
for path in list(scripts.glob("*.lua")) + list((root / "TS2Probe" / "Scripts").glob("*.lua")):
    result = lua.eval("function(src, name) local f, err = load(src, name); return err end")(path.read_text(encoding="utf-8"), "@" + path.name)
    if result:
        print("SYNTAX ERROR", path.name, result); bad += 1
    else:
        print("syntax ok  ", path.relative_to(root))
lua.execute('package.path = "%s/?.lua;" .. package.path' % str(scripts).replace("\\", "/"))
failures = lua.execute(pathlib.Path(root / "tests" / "camera_math_test.lua").read_text(encoding="utf-8"))
sys.exit(1 if (bad or failures) else 0)
