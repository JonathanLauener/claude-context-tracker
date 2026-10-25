#!/usr/bin/env python3
"""Patch the Claude Code binary so the statusline reflects the subagent being viewed.

When you enter a subagent's view, the statusline command gets that agent's messages
(context_window computed from them) plus a `viewed_agent` object. Back in the main
view everything is as before.

How: Claude Code is a Bun standalone binary whose modules ship as source + JSC
bytecode. Bun runs the bytecode, so for the two patched modules the bytecode length
in the module table is set to 0 and Bun falls back to the (patched) source. Each
module keeps its exact byte length: the legal header comment is shortened to make room.

Usage: patch.py <input-binary> <output-binary>
"""
import struct
import sys

TRAILER = b"\n---- Bun! ----\n"
ENTRY = 52  # name, contents, sourcemap, bytecode, module_info, origin (6x StringPointer) + 4 flag bytes

# --- statusline store (class y0n) + JSON builder (VGn) ----------------------
AUG = (
    b'function __ccAug(F,n){let w=globalThis.__ccView;if(!w)return F;let t=w.task,'
    b'a=n.findLast((x)=>x.type==="assistant")?.message?.model,k=(x)=>String(x).replace(/\\[1m\\]$/i,"");'
    b'F.viewed_agent={task_id:t.id,agent_id:t.agentId,description:t.description,agent_type:t.agentType,'
    b'status:t.status,model:a??t.model??null};'
    b'if(a&&k(a)!==k(F.model.id))try{F.context_window=xTe(wve(n),Hg(a,ym()));F.model={id:a,display_name:wi(a)}}catch{}'
    b'return F}'
)
STORE_PATCHES = [
    (b"function VGn({session:e,permissionMode:n,", AUG + b"function VGn({session:e,permissionMode:n,"),
    (b"class y0n{#e;#t;#n;", b"class y0n{__v=()=>{if(this.#a)this.#y()};#e;#t;#n;"),
    (b"let n=oa(this.#e.getMessages()),r=this.#p;",
     b"let __w=globalThis.__ccView,n=oa(__w?__w.messages??[]:this.#e.getMessages()),r=this.#p;"),
    (b"let M=this.#t,F=VGn({session:g,", b"let M=this.#t,F=__ccAug(VGn({session:g,"),
    (b"thinkingEnabled:M.thinkingEnabled});if(!e.aborted)this.#T(izn(F))",
     b"thinkingEnabled:M.thinkingEnabled}),n);if(!e.aborted)this.#T(izn(F))"),
]

# --- statusline React component (KLe) --------------------------------------
SEL = (
    b"function __ccT(s){return s.viewingAgentTaskId?s.tasks[s.viewingAgentTaskId]:void 0}"
    b"function __ccM(s){let t=__ccT(s);return t?s.transcripts[t.id]?.messages:void 0}"
)
COMPONENT_PATCHES = [
    (b"function KLe(h){let Ze=w(40),", SEL + b"function KLe(h){let Ze=w(40),"),
    (b"let[So]=g(jt),Po,ko;",
     b"let[So]=g(jt),Po,ko,__t=W(__ccT),__m=W(__ccM);"
     b"globalThis.__ccView=__t?{task:__t,messages:__m}:void 0;"
     b"C(()=>{So.__v?.()},[So,__t?.id,__m]);"),
]

TARGETS = [
    (b"class y0n{#e;#t;#n;", STORE_PATCHES),
    (b"function KLe(h){let Ze=w(40),", COMPONENT_PATCHES),
]

LEGAL_START = b"// Claude Code is a Beta product"
LEGAL_END = b"// Version: "


def section_base(b):
    """File offset of the .bun section payload (section starts with a u64 size)."""
    shoff, = struct.unpack_from("<Q", b, 0x28)
    shentsize, shnum, shstrndx = struct.unpack_from("<HHH", b, 0x3A)
    def sh(i):
        return struct.unpack_from("<IIQQQQ", b, shoff + i * shentsize)
    strtab_off = sh(shstrndx)[4]
    for i in range(shnum):
        name_off, _, _, _, off, _ = sh(i)
        end = b.index(b"\0", strtab_off + name_off)
        if b[strtab_off + name_off:end] == b".bun":
            return off + 8
    sys.exit("no .bun section found")


def modules(b, base):
    t = b.rfind(TRAILER)
    mo, ml = struct.unpack_from("<II", b, t - 24)
    for i in range(ml // ENTRY):
        e = base + mo + i * ENTRY
        u = struct.unpack_from("<13I", b, e)
        yield dict(entry=e, name=bytes(b[base + u[0]:base + u[0] + u[1]]).decode(),
                   start=base + u[2], length=u[3], bytecode_len=u[7])


def patch_module(b, mod, patches):
    src = bytes(b[mod["start"]:mod["start"] + mod["length"]])
    for old, new in patches:
        n = src.count(old)
        if n != 1:
            sys.exit(f"{mod['name']}: anchor found {n}x (expected 1): {old[:60]!r}")
        src = src.replace(old, new)
    grow = len(src) - mod["length"]
    ls, le = src.find(LEGAL_START), src.find(LEGAL_END)
    if ls < 0 or le < 0 or le - ls < grow + 1:
        sys.exit(f"{mod['name']}: not enough room in header comment ({grow} bytes needed)")
    comment = b"// patched: subagent statusline\n"
    comment = comment + b" " * ((le - ls) - grow - len(comment))
    if len(comment) != (le - ls) - grow or (le - ls) - grow < 33:
        sys.exit(f"{mod['name']}: header comment too small")
    src = src[:ls] + comment + src[le:]
    assert len(src) == mod["length"]
    b[mod["start"]:mod["start"] + mod["length"]] = src
    struct.pack_into("<I", b, mod["entry"] + 28, 0)  # bytecode length -> 0: run source
    print(f"patched {mod['name']} (+{grow} bytes code, bytecode disabled)")


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    b = bytearray(open(sys.argv[1], "rb").read())
    base = section_base(b)
    mods = list(modules(b, base))
    for anchor, patches in TARGETS:
        hits = [m for m in mods if b.find(anchor, m["start"], m["start"] + m["length"]) >= 0]
        if len(hits) != 1:
            sys.exit(f"module for {anchor!r}: {len(hits)} matches (already patched or new version?)")
        patch_module(b, hits[0], patches)
    with open(sys.argv[2], "wb") as f:
        f.write(b)


if __name__ == "__main__":
    main()
