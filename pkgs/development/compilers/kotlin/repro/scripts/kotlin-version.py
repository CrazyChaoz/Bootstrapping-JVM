"""kotlin-version.py IN VERSION OUT: KotlinVersion.kt with KotlinVersion.CURRENT's components set from
VERSION, as prepare/build.version's writeStdlibVersion task does before the stdlib's compilation."""
import re
import sys

src, version, out = sys.argv[1:]
m = re.match(r"^(\d+)\.(\d+)(\.(\d+))?", version)
parts = "%s, %s, %s" % (m.group(1), m.group(2), m.group(4) or "0")
text, n = re.subn(
    r"(fun get\(\): KotlinVersion = KotlinVersion\()\d+, \d+, \d+\)",
    lambda g: g.group(1) + parts + ")",
    open(src).read(),
)
assert n == 1, "version pattern not found"
open(out, "w").write(text)
