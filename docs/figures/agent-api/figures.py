#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""The figures of docs/agent-api.md: run `./figures.py` to write every SVG beside this file.

A figure is a piece of a run in three columns with aligned rows: what the program does, who
carries it out, and the log. Its spec (at the end of this file) is a list of rows; the kind of a
row, its icon, its constructor, its chip and its frame's box all follow from the row's text, as
the report's `summary()` words it. The look is docs/style_guide.md; the icons are read from
Alaya/Html/page.js.
"""

import re
from html import escape
from pathlib import Path

HERE = Path(__file__).resolve().parent
PAGE_JS = HERE.parents[2] / "Alaya" / "Html" / "page.js"

# --- the style guide's values -------------------------------------------------------------

INK, MUTE, FAINT, LINE, GUIDE, SIDE, SOFT = "#1c1e21", "#6f7985", "#a3abb5", "#e3e6ea", "#d3d9e0", "#fafbfc", "#f6f7f9"
BLUE, TEAL, VIOLET, GREEN, RED, AMBER, ROOT = "#3567a0", "#2b6f6f", "#7556a3", "#2a7a4b", "#b3261e", "#a8690f", "#4a4f57"
SANS = "-apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif"
MONO = "ui-monospace, SFMono-Regular, Menlo, Consolas, monospace"
STYLE = f"""
text{{font-family:{SANS};font-size:13px;fill:{INK}}}
.m{{font-family:{MONO}}}
.s{{font-size:11px;fill:{MUTE}}}
.f{{font-size:11px;fill:{FAINT}}}
.b{{font-weight:600}}
.n{{font-variant-numeric:tabular-nums}}
.fr{{font-family:{MONO};font-size:11.5px;fill:{FAINT}}}
.ch{{font-family:{MONO};font-size:12px}}
.e{{font-family:{MONO};font-size:11.5px}}
.a{{stroke:{FAINT};fill:none}}
.d{{stroke-dasharray:3 3}}
.bx{{stroke:{GUIDE};fill:none}}
""".replace("\n", "")

# --- geometry -----------------------------------------------------------------------------

WIDTH = 920
ROW, GAP_H, DIV_H, LINE_H, ROUND_H = 24, 18, 22, 14, 18
INDENT, INSET, PAD = 14, 4, 8  # a level of nesting at the left, at the right; a box's padding


class Columns:
    """Where the columns are. `workspace` adds the column of versions at the far right."""

    def __init__(self, workspace=False):
        self.p0 = 12
        self.p1 = self.m0 = 264 if workspace else 298   # program | carried out by
        self.m1 = self.l0 = self.m0 + 142                # carried out by | log
        self.l1 = 810 if workspace else 914
        self.pos = self.l0 + 20                          # positions end here
        self.frame = self.l0 + 28
        self.icon = self.l0 + 87
        self.text = self.l0 + 106
        self.ctor = self.l1 - (8 if workspace else 16)   # constructors end here
        self.arc = self.l1 - 13                          # the arcs of `takes`
        self.version = 892.5                             # the line of versions


# --- kinds of rows ------------------------------------------------------------------------

# How a row's text begins → its glyph, colour, constructor, role, and who answers.
KINDS = [
    ("the workspace the run starts from", "root", ROOT, "arrived", "notice", None),
    ("said ", "said", VIOLET, "arrived", "notice", None),
    ("workspace changed", "changed", VIOLET, "arrived", "notice", None),
    ("replied ", "replied", VIOLET, "arrived", "notice", None),
    ("assigned ", "assigned", VIOLET, "arrived", "notice", None),
    ("inbox", "heard", FAINT, "heard", "ask", "the log"),
    ("sample failed", "fail", RED, "answered", "ask", "model"),
    ("sample", "sample", BLUE, "answered", "ask", "model"),
    ("exec", "exec", TEAL, "answered", "ask", "executor"),
    ("external", "external", TEAL, "answered", "ask", "container"),
    ("time", "time", FAINT, "answered", "ask", "clock"),
    ("open ask_user", "question", AMBER, "opened", "open", None),
    ("open ", "open", MUTE, "opened", "open", None),
    ("return", "return", GREEN, "returned", "end", None),
    ("fail", "fail", RED, "failed", "end", None),
    ("stopped", "stop", RED, "stopped", "stop", None),
    ("#", "comment", FAINT, "commented", "comment", None),
]
CHIP_BORDER = {"heard": VIOLET, "time": FAINT}  # otherwise the colour of the row's icon


def kind_of(text):
    return next(k for k in KINDS if text.startswith(k[0]))


def default_chip(text):
    """What the program wrote to get this row: `exec "make"` for `exec make → exit 0`."""
    word = text.split()[0].rstrip(":")
    if word in ("exec", "external"):
        return f'{word} "{text[len(word) + 1:].split(" →")[0]}"'
    return "sample request" if word == "sample" else word


# --- row specs ----------------------------------------------------------------------------

def R(pos, frame, text, **options):
    """A log row. Options: chip (its text, when not the default), end (the text of a frame's
    end, when not `return` / `fail`), note, by (more about the person), opens (a frame with no
    `opened` event: the run's), ws / on / checkout (the version of the workspace the row leaves,
    the one it runs on, the checkout it makes)."""
    return dict(type="row", pos=pos, frame=frame, text=text, **options)


def GAP(note=None, off=0, on=None):
    """Rows left out. `off` innermost frames run off here; a frame labelled `on` runs in."""
    return dict(type="gap", note=note, off=off, on=on)


def DIV(text):
    """A dashed line across the figure: where the driver stops."""
    return dict(type="div", text=text)


def NOTE(text):
    """A note between two rows, in the innermost frame open there."""
    return dict(type="note", text=text)


def ROUND(text, rows):
    """The label of a round of a loop, bracketing the next `rows` rows."""
    return dict(type="round", text=text, rows=rows)


# --- text and shapes ----------------------------------------------------------------------

EMS = dict.fromkeys(" .,:;'’‘|!iljI", 0.27) | dict.fromkeys("frt()[]“”\"-/·", 0.37) | \
    dict.fromkeys("mw", 0.86) | dict.fromkeys("MW→…", 0.95)


def width(text, size=13, mono=False):
    """An estimate of a text's width, a few percent on the wide side of the system's sans.
    SVG cannot measure text, so look at the figure after a change. Backticks set monospace."""
    total = 0
    for i, part in enumerate(text.split("`")):
        if mono or i % 2:
            total += len(part) * 0.605 * size
        else:
            ems = sum(EMS.get(c, 0.7 if c.isupper() else 0.63 if c.isdigit() else 0.57) for c in part)
            total += ems * size * (1.03 if size < 12 else 1)
    return total


def wrap(text, limit, size=11):
    """The text in as few lines as fit in `limit`, and those as even as they can be."""
    def fill(limit):
        lines = [""]
        for word in re.findall(r"`[^`]*`\S*|\S+", text):
            longer = (lines[-1] + " " + word).strip()
            if lines[-1] and width(longer, size) > limit:
                lines.append(word)
            else:
                lines[-1] = longer
        return lines

    lines = fill(limit)
    while True:
        tighter = fill(max(width(line, size) for line in lines) - 1)
        if len(tighter) > len(lines) or tighter == lines:
            return lines
        lines = tighter


def n(value):
    return f"{value:.1f}".rstrip("0").rstrip(".")


def label(x, y, text, cls="", fill=None, anchor=None):
    """A line of text; what is between backticks is monospace."""
    attrs = (f' class="{cls}"' if cls else "") + (f' style="fill:{fill}"' if fill else "") + \
        (f' text-anchor="{anchor}"' if anchor else "")
    spans = "".join(f'<tspan class="m">{escape(part, False)}</tspan>' if i % 2 else escape(part, False)
                    for i, part in enumerate(text.split("`")))
    return f'<text x="{n(x)}" y="{n(y)}"{attrs}>{spans}</text>'


def arrow(x0, x1, y, dashed=False):
    """A 1px arrow along a row, its head at x1."""
    s = 1 if x1 > x0 else -1
    return (f'<path class="a{" d" if dashed else ""}" d="M{n(x0)},{n(y)}H{n(x1 - 4 * s)}"/>'
            f'<path fill="{FAINT}" d="M{n(x1)},{n(y)}l{-5 * s},-2.5v5z"/>')


def box(x0, y0, x1, y1, top, bottom, fill):
    """A frame's box; a side that is not `top` / `bottom` is open: no border, no corners."""
    rt, rb = (6 if top else 0), (6 if bottom else 0)
    left = f"M{x0},{y1 - rb}V{y0 + rt}"
    over = f"Q{x0},{y0} {x0 + rt},{y0}H{x1 - rt}Q{x1},{y0} {x1},{y0 + rt}"
    under = f"Q{x1},{y1} {x1 - rb},{y1}H{x0 + rb}Q{x0},{y1} {x0},{y1 - rb}"
    ground = left + (over if top else f"H{x1}") + f"V{y1 - rb}" + (under if bottom else f"H{x0}") + "Z"
    border = left + (over if top else f"M{x1},{y0}") + f"V{y1 - rb}" + (under if bottom else "")
    return f'<path fill="{fill}" d="{ground}"/><path class="bx" d="{border}"/>'


def dot(x, y, r, fill, stroke=None):
    return f'<circle cx="{n(x)}" cy="{n(y)}" r="{r}" fill="{fill}"' + (f' stroke="{stroke}"/>' if stroke else "/>")


GLYPHS = dict(re.findall(r"(\w+): '([^']*)'",
                         re.search(r"const GLYPHS = \{(.*?)\n\};", PAGE_JS.read_text(), re.S).group(1)))


def icon(x, cy, glyph, color):
    return (f'<g transform="translate({n(x)},{n(cy - 6.5)}) scale({13 / 14:.4f})" stroke="{color}" fill="{color}" '
            f'stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">{GLYPHS[glyph]}</g>')


# --- drawing a figure ---------------------------------------------------------------------

class Program:
    """The program column while the rows are drawn: the frames open at the row, their boxes."""

    def __init__(self, columns, out):
        self.c, self.out, self.stack, self.boxes = columns, out, [], []

    def inner(self):
        """The left and the right of the inside of the innermost frame."""
        return (self.stack[-1]["x0"] + PAD, self.stack[-1]["x1"] - PAD) if self.stack else (self.c.p0, self.c.p1)

    def open(self, text, y0, cy, closed=True, run=False):
        d = len(self.stack)
        x0, x1 = self.c.p0 + INDENT * d + .5, self.c.p1 - INSET * d - .5
        self.stack.append(dict(x0=x0, x1=x1, y0=y0, top=closed, depth=d, run=run))
        self.out.append(label(x0 + PAD, cy + 4, text, "s b"))

    def close(self, y1, closed=True):
        f = self.stack.pop()
        fill = SIDE if f["depth"] % 2 == 0 else "#fff"
        self.boxes.append((f["depth"], box(f["x0"], f["y0"], f["x1"], y1, f["top"], closed, fill)))

    def note(self, text, y0):
        """A note in the innermost frame, from y0 down; the height it takes."""
        x0, x1 = self.inner()
        lines = wrap(text, x1 - x0 + PAD / 2)
        self.out.extend(label(x0, y0 + 10 + LINE_H * i, line, "s") for i, line in enumerate(lines))
        return LINE_H * len(lines) + 2

    def chip(self, text, border, who, cy):
        """What the program asks for, with the arrows to the log and back."""
        c, x0 = self.c, self.inner()[0]
        w = width(text, 12, mono=True) + 12
        middle, lw = (c.m0 + c.m1) / 2, width(who, 11)
        self.out += [
            f'<rect x="{x0 + .5}" y="{cy - 9}" width="{n(w)}" height="18" rx="4" fill="{SOFT}" stroke="{border}"/>',
            label(x0 + 6.5, cy + 4, text, "ch"),
            arrow(x0 + w + 5, c.l0 - 4, cy - 4.5),
            f'<rect x="{n(middle - lw / 2 - 4)}" y="{cy - 11}" width="{n(lw + 8)}" height="13" fill="#fff"/>',
            label(middle, cy - 1, who, "s", anchor="middle"),
            arrow(c.l0 - 4, x0 + w + 5, cy + 5.5, dashed=True),
        ]

    def cut(self, y, note):
        """A stop: every frame but the run's own ends here, with no mark."""
        cut = [f for f in self.stack if not f["run"]]
        for _ in cut:
            self.close(y, closed=False)
        if cut:
            self.out.append(f'<path stroke="{RED}" d="M{cut[0]["x0"]},{y}H{cut[0]["x1"]}"/>')
        if cut and note:
            self.out.append(label(cut[0]["x0"] + PAD, y + 13, note, "s", RED))


def figure(name, title, rows, inside=(), takes=False, heads=False, legend=False, foot=(), workspace=None):
    """Write `name`.svg. `inside`: the frames already open above the first row. `takes`: draw an
    arc from a read to each notice it took. `heads`: name the log's columns. `legend`: explain the
    arrows. `foot`: lines of notes under the figure. `workspace`: the note of the column of
    versions; giving it draws the column."""
    c, out = Columns(workspace is not None), []
    program = Program(c, out)
    top = y = 41 if heads else 26
    for text in inside:
        program.open(text, y + .5, y + GAP_H / 2, closed=False)

    at, reads, versions, bracket = {}, [], [], None  # at: the middle of the row of a position
    for r in rows:
        kind, h, cy = r["type"], ROW, y + ROW / 2
        if kind == "gap":
            h, cy = GAP_H, y + GAP_H / 2
            out.extend(dot(c.pos - 4, cy + dy, .9, FAINT) for dy in (-4, 0, 4))
            if r["note"]:
                out.append(label(c.text, cy + 4, r["note"], "s"))
            for _ in range(r["off"]):
                program.close(y + h - 3.5, closed=False)
            if r["on"]:
                program.open(r["on"], y + 3.5, cy, closed=False)
        elif kind == "div":
            h, cy = DIV_H, y + DIV_H / 2 + .5
            end = c.text + width(r["text"], 11) + 8
            out.append(f'<path stroke="{AMBER}" stroke-dasharray="4 3" d="M4,{cy}H{c.text - 8}M{n(end)},{cy}H{c.l1}"/>')
            out.append(label(c.text, cy + 3.5, r["text"], "s", AMBER))
        elif kind == "note":
            h = program.note(r["text"], y)
        elif kind == "round":
            h = ROUND_H
            out.append(label(program.inner()[0], y + 13, r["text"], "s"))
            bracket = [y + 4.5, r["rows"] + 1]
        else:
            prefix, glyph, color, ctor, role, who = kind_of(r["text"])
            at[r["pos"]] = cy
            # the log
            ink = VIOLET if role == "notice" and glyph != "root" else MUTE if role == "comment" else None
            out += [label(c.pos, cy + 4, str(r["pos"]), "f n", anchor="end"), label(c.frame, cy + 4, r["frame"], "fr"),
                    icon(c.icon, cy, glyph, color), label(c.text, cy + 4.5, r["text"], fill=ink),
                    label(c.ctor, cy + 4, ctor, "f", anchor="end")]
            if width(r["text"]) + width(ctor, 11) + 8 > c.ctor - c.text:
                print(f"  {name}: row {r['pos']} may not fit: {r['text']}")
            # the program, and who carries out what it asks for
            if r.get("opens"):
                program.open(r["opens"], y + 2.5, cy, run=True)
            if role in ("notice", "stop"):  # from outside: nothing comes from the program
                by = "a person" + (" · " + r["by"] if r.get("by") else "")
                out += [label(c.m0 + 6, cy - 2.5, by, "s"), arrow(c.m0 + 9, c.l0 - 4, cy + 5.5),
                        dot(c.m0 + 9, cy + 5.5, 2.5, RED if role == "stop" else VIOLET)]
            if role == "stop":
                program.cut(y + 6.5, r.get("note"))
            elif role == "open":
                program.open(r["text"].split()[1].rstrip(":") + " · " + r["frame"], y + 2.5, cy)
                out.append(arrow(program.stack[-1]["x1"] + 1, c.l0 - 4, cy + .5))
            elif role == "end":
                x0, x1 = program.inner()
                out += [label(x1, cy + 4, r.get("end", prefix), "e", color, "end"), arrow(x1 + PAD + 1, c.l0 - 4, cy + .5)]
                if r.get("note"):  # beside the end, not under it
                    out.append(label(x0, cy + 4, r["note"], "s"))
                program.close(y + ROW - 2.5)
            elif role == "ask":
                program.chip(r.get("chip", default_chip(r["text"])), CHIP_BORDER.get(glyph, color), who, cy)
                if glyph == "heard":
                    reads.append((cy, [int(p) for p in re.findall(r"\d+", r["text"])]))
            if r.get("note") and role in ("open", "ask"):
                h += program.note(r["note"], y + ROW - 2) - 1
            if r.get("ws") or r.get("checkout"):
                versions.append((cy, r))
        if bracket:
            bracket[1] -= 1
            if bracket[1] == 0:
                out.append(f'<path class="a" d="M8,{bracket[0]}H4.5V{y + h - 3.5}H8"/>')
                bracket = None
        y += h
    bottom = y
    while program.stack:
        program.close(bottom - .5, closed=False)

    if takes:  # from a read to each notice it took
        x = c.arc
        for cy, taken in reads:
            for to in (at[pos] for pos in taken):
                out.append(f'<path class="a" style="stroke:{VIOLET}" d="M{x},{cy}C{x + 13},{cy} {x + 13},{to} {x + 3},{to}"/>'
                           f'<path fill="{VIOLET}" d="M{x - 1},{to}l5,-2.5v5z"/>')

    if versions:  # the versions of the workspace, down a line
        x = c.version
        out.append(f'<path class="a" d="M{x},{versions[0][0]}V{versions[-1][0] + ROW / 2}"/>')
        for cy, r in versions:
            if r.get("checkout"):
                out += [f'<path class="a d" d="M{x},{cy}H{x - 34}"/>', dot(x - 36, cy, 3.5, "#fff", MUTE),
                        label(x - 44, cy + 4, r["checkout"], "s m", anchor="end")]
            else:
                out += [dot(x, cy, 3.5, "#fff", MUTE), label(x + 8, cy + 4, r["ws"], "s m")]
            if r.get("on"):
                out.append(label(x - 9, cy + 4, f"runs on `{r['on']}` →", "s", anchor="end"))

    # around the rows: the heads of the columns, the ground of the log, what is said below
    head = [label(c.p0, 14, "program", "s"), label(c.m0 + 6, 14, "carried out by", "s"), label(c.l0 + 7, 14, "log", "s")]
    if heads:
        head += [label(c.pos, 31, "position", "f", anchor="end"), label(c.frame, 31, "frame", "f"),
                 label(c.icon, 31, "event", "f")]
    if versions:
        head.append(label(WIDTH - 6, 14, "workspace", "s", anchor="end"))
    panel = (f'<rect x="{c.l0 + .5}" y="{top - 3.5}" width="{c.l1 - c.l0}" height="{bottom - top + 7}" rx="6" '
             f'fill="{SIDE}" stroke="{LINE}"/>')
    y = bottom + 10
    if workspace:
        out.append(label(WIDTH - 6, y + 10, workspace, "s", anchor="end"))
        y += 16
    if legend:
        x = c.p0
        samples = [
            (arrow(x, x + 66, 0) + f'<rect x="{x + 14}" y="-7" width="34" height="13" fill="#fff"/>'
             + label(x + 31, 3.5, "model", "s", anchor="middle"),
             "the program asks; the driver carries it out and appends the answer"),
            (arrow(x + 66, x, 0, dashed=True), "on replay the answer is read back from the log"),
            (arrow(x, x + 66, 0), "a mark of what the program did: a call opened, a call ended"),
        ]
        for sample, text in samples:
            out.append(f'<g transform="translate(0,{y + 6.5})">{sample}</g>' + label(x + 78, y + 10, text, "s"))
            y += 17
    for line in foot:
        out.append(label(c.p0, y + 10, line, "s"))
        y += 16
    height = int(y + 6 if y > bottom + 10 else bottom + 8)

    frames = [svg for _, svg in sorted(program.boxes, key=lambda b: b[0])]  # outer boxes first
    svg = (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {WIDTH} {height}" width="{WIDTH}" height="{height}">\n'
           f"<title>{escape(title)}</title>\n<style>{STYLE}</style>\n"
           f'<rect width="{WIDTH}" height="{height}" fill="#fff"/>\n'
           + "\n".join(head + [panel] + frames + out) + "\n</svg>\n")
    (HERE / f"{name}.svg").write_text(svg)
    print(f"{name}.svg  {WIDTH}×{height}")


# --- the figures --------------------------------------------------------------------------

ROOT_ROW = R(0, "-", "the workspace the run starts from")

figure("log", "The log of a small agent, beside its program", [
    ROOT_ROW,
    R(1, "0", "open agent"),
    R(2, "-", "said “fix the build”"),
    R(3, "0", "inbox: takes 2", chip="await"),
    R(4, "0", "sample → says “run make”"),
    R(5, "0", "exec make → exit 0"),
    R(6, "0", "return fixed", end='return "fixed"'),
], heads=True, legend=True)

figure("perform", "Three operations, each answered by its part of the world", [
    GAP(),
    R(7, "0", "sample → says “run the tests”"),
    R(8, "0", "exec pytest -q → exit 1"),
    R(9, "0", "time 4 min 12 s of 1 h"),
    GAP(),
], inside=["agent · 0"])

figure("workspace", "The versions of the workspace along a log", [
    R(0, "-", "the workspace the run starts from", ws="w0"),
    R(1, "0", "open agent"),
    GAP(on="bash · 0.0"),
    R(5, "0.0", "exec make → exit 0", ws="w1", on="w0"),
    GAP(off=1),
    R(9, "-", "workspace changed: fixed the Makefile", ws="w2"),
    GAP(on="bash · 0.1"),
    R(12, "0.1", "exec make test → exit 0", ws="w3", on="w2"),
    GAP(off=2),
    R(40, "-", "external pytest /grader → exit 0", checkout="c1"),
], workspace="a checkout: the workspace stays at `w3`")

figure("inbox", "Notices arrive from outside, and reads take them", [
    ROOT_ROW,
    R(1, "0", "open agent"),
    R(2, "-", "said “fix the build”"),
    R(3, "0", "inbox: takes 2", chip="await", note="waits until a notice it is for has arrived"),
    R(4, "0", "sample → bash make"),
    GAP(),
    R(9, "-", "said “use ninja, not make”", by="at any time"),
    GAP(),
    R(12, "0", "inbox: takes 9"),
    R(13, "0", "sample → bash ninja"),
    GAP(),
    R(17, "0", "inbox: nothing"),
    GAP(),
], takes=True)

figure("call", "Two calls of a routine, each a bracket in the log", [
    ROOT_ROW,
    R(1, "0", "open agent"),
    R(2, "0.0", "open step “make”"),
    R(3, "0.0", "exec make → exit 0"),
    R(4, "0.0", "return 0", end="return 0"),
    R(5, "0.1", "open step “make test”"),
    R(6, "0.1", "exec make test → exit 1"),
    R(7, "0.1", "return 1", end="return 1"),
    R(8, "0", "return 2 steps, 1 failed"),
], foot=["a child frame is its caller’s frame and the call’s ordinal"])

figure("failure", "A failed sample ends its routine, and the caller catches the failure", [
    ROOT_ROW,
    R(1, "0", "open agent"),
    R(2, "0.0", "open planner “ship it”"),
    R(3, "0.0", "sample failed: the request is too long",
      note="the answer is an error: the operation fails where it was performed"),
    R(4, "0.0", "fail: the request is too long"),
    NOTE("`try … catch`: the caller catches the error; no mark"),
    R(5, "0.1", "open step “make”"),
    R(6, "0.1", "exec make → exit 0"),
    R(7, "0.1", "return 0", end="return 0"),
    R(8, "0", "return built without a plan"),
])

figure("loop", "A loop of three rounds: the log holds their events, flat", [
    ROOT_ROW,
    R(1, "0", "open agent"),
    R(2, "-", "said “fix the build”"),
    R(3, "0", "inbox: takes 2", chip="await"),
    ROUND("round 1 · state: 2 messages", 4),
    R(4, "0", "sample → bash make"),
    R(5, "0.0", "open bash “make”"),
    R(6, "0.0", "exec make → exit 2"),
    R(7, "0.0", "return exit 2: no rule to make target"),
    ROUND("round 2 · 4 messages", 4),
    R(8, "0", "sample → bash ninja"),
    R(9, "0.1", "open bash “ninja”"),
    R(10, "0.1", "exec ninja → exit 0"),
    R(11, "0.1", "return exit 0: build ok"),
    ROUND("round 3 · 6 messages → result", 1),
    R(12, "0", "sample → says “fixed: use ninja”"),
    R(13, "0", "return fixed: use ninja"),
], foot=["a loop writes nothing of its own; every round reads an event"])

figure("stop", "A stop ends every frame of the agent, and the run goes on to its grading", [
    R(0, "-", "the workspace the run starts from", opens="run · -"),
    R(1, "0", "open agent"),
    R(2, "0.0", "open workflow “ship it”"),
    R(3, "0.0.0", "open planner “ship it”"),
    R(4, "0.0.0", "sample → lookup build"),
    R(5, "-", "stopped: to grade this point", note="every frame of the agent ends; no marks"),
    DIV("the agent is over: the run waits for a grader"),
    R(6, "-", "assigned grader “pytest /grader”"),
    R(7, "-", "inbox: takes 6", chip="await"),
    R(8, "-", "external pytest /grader → exit 1"),
    R(9, "-", "return fail 12/48", end="return verdict"),
])

figure("routines", "The log of the workflow, its sub-agent and their tools", [
    ROOT_ROW,
    R(1, "0", "open agent"),
    R(2, "-", "said “ship it”"),
    R(3, "0", "inbox: takes 2", chip="await"),
    R(4, "0.0", "open workflow “ship it”"),
    R(5, "0.0.0", "open planner “ship it”"),
    R(6, "0.0.0", "sample → lookup build"),
    R(7, "0.0.0.0", "open lookup “build”"),
    R(8, "0.0.0.0", "exec grep build notes.txt → exit 0"),
    R(9, "0.0.0.0", "return build: make"),
    R(10, "0.0.0", "sample → says “make make test”"),
    R(11, "0.0.0", "return steps: make, make test"),
    R(12, "0.0.1", "open step “make”"),
    R(13, "0.0.1", "exec make → exit 0"),
    R(14, "0.0.1", "return 0"),
    R(15, "0.0.2", "open step “make test”"),
    R(16, "0.0.2", "exec make test → exit 1"),
    R(17, "0.0.2", "return 1"),
    R(18, "0.0", "return 2 steps, 1 failed"),
    R(19, "0", "return 2 steps, 1 failed"),
])

figure("tool-call", "A response that asks for two tools, and the two calls it becomes", [
    GAP(),
    R(10, "0", "inbox: nothing"),
    R(11, "0", "sample → bash make; bash make test", note="the response asks for two tools"),
    NOTE("each: check its arguments, then `call name arguments`"),
    R(12, "0.3", "open bash “make”"),
    R(13, "0.3", "exec make → exit 0"),
    R(14, "0.3", "return exit 0: build ok"),
    R(15, "0.4", "open bash “make test”"),
    R(16, "0.4", "exec make test → exit 1"),
    R(17, "0.4", "return exit 1: 1 test failed"),
    R(18, "0", "inbox: nothing"),
    R(19, "0", "sample → says “one test fails”", note="the next request holds both results"),
    GAP(),
], inside=["agent · 0"])

figure("ask-user", "A question: the call opens, the run waits, a person replies, the call returns", [
    GAP(),
    R(10, "0", "inbox: nothing"),
    R(11, "0", "sample → ask_user Should duplicates be kept?"),
    R(12, "0.2", "open ask_user “Should duplicates be kept?”",
      note="the question is the call’s arguments: it is in the log"),
    DIV("the driver stops: the call waits for a reply to 0.2"),
    R(13, "-", "replied to 0.2: yes", by="`alaya reply`"),
    R(14, "0.2", "inbox: takes 13", chip="await"),
    R(15, "0.2", "return yes", end='return "yes"'),
    R(16, "0", "inbox: nothing", note="a plain read leaves replies"),
    R(17, "0", "sample → bash sort -u names.txt", note="the model is shown `yes` as the tool’s result"),
    GAP(),
], inside=["agent · 0"], takes=True)

figure("run", "A whole run: the agent in frame 0, then its grading in the run’s own frame", [
    R(0, "-", "the workspace the run starts from", by="`alaya new`", opens="run · -"),
    R(1, "0", "open agent: mini-swe, gpt-6-luna", note="the call’s arguments are the run’s configuration"),
    R(2, "-", "said “Implement SPEC.md”"),
    R(3, "0", "inbox: takes 2", chip="await"),
    GAP("the agent’s rounds"),
    R(41, "0", "return Submitted: implemented the language"),
    DIV("the agent is over: the run waits for a grader"),
    R(42, "-", "assigned grader “pytest /grader”", by="`alaya grade`"),
    R(43, "-", "inbox: takes 42", chip="await"),
    R(44, "-", "external pytest /grader → exit 0"),
    R(45, "-", "return pass 48/48", note="the result of the run"),
])
