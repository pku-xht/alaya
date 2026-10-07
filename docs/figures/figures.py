#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""The figures of the documents: run `./figures.py` to write every SVG into the directory of its
document beside this file: `agent-api/` for docs/language.md, docs/runtime.md and
docs/agents.md, `llm-api/` for docs/llm-api.md, `log-schema/` for docs/log-schema.md and `cli/`
for docs/cli.md.

The look is docs/style_guide.md; the icons are read from Alaya/App/Html/page.js. The file has five
parts: what every figure is drawn with (the style's values, text, shapes), then the figures of
language.md, runtime.md and agents.md, those of llm-api.md, those of log-schema.md, and those of
cli.md. SVG cannot measure text, so a width here is an estimate: after changing a label, run the script and look at
the figure.
"""

import re
from html import escape
from pathlib import Path

HERE = Path(__file__).resolve().parent
PAGE_JS = HERE.parents[1] / "Alaya" / "App" / "Html" / "page.js"

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
WIDTH = 920  # of every figure

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


def write(folder, name, title, height, parts, style=STYLE):
    """Write the figure `folder`/`name`.svg: its title, the style, a white ground, its parts."""
    svg = (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {WIDTH} {height}" width="{WIDTH}" height="{height}">\n'
           f"<title>{escape(title)}</title>\n<style>{style}</style>\n"
           f'<rect width="{WIDTH}" height="{height}" fill="#fff"/>\n'
           + "\n".join(parts) + "\n</svg>\n")
    (HERE / folder).mkdir(exist_ok=True)
    (HERE / folder / f"{name}.svg").write_text(svg)
    print(f"{folder}/{name}.svg  {WIDTH}×{height}")


# === docs/language.md, docs/runtime.md, docs/agents.md ====================================================================
#
# A figure is a piece of a run in three columns with aligned rows: what the program does, who
# carries it out, and the log. Its spec (below, after the kit) is a list of rows; the kind of a
# row, its icon, its constructor, its chip and its frame's box all follow from the row's text, as
# the report's `summary()` words it.

# --- geometry -----------------------------------------------------------------------------

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
        self.icon = self.l0 + 97
        self.text = self.l0 + 116
        self.ctor = self.l1 - (8 if workspace else 16)   # constructors end here
        self.arc = self.l1 - 13                          # the arcs of `takes`
        self.version = 892.5                             # the line of versions


# --- kinds of rows ------------------------------------------------------------------------

# How a row's text begins → its glyph, colour, constructor, role, and who answers.
KINDS = [
    ("the workspace", "root", ROOT, "arrived", "notice", None),
    ("said ", "said", VIOLET, "arrived", "notice", None),
    ("workspace changed", "changed", VIOLET, "arrived", "notice", None),
    ("replied ", "replied", VIOLET, "arrived", "notice", None),
    ("call ", "called", VIOLET, "arrived", "notice", None),
    ("inbox", "heard", FAINT, "heard", "ask", "the log"),
    ("sample failed", "fail", RED, "answered", "ask", "model"),
    ("sample", "sample", BLUE, "answered", "ask", "model"),
    ("exec", "exec", TEAL, "answered", "ask", "executor"),
    ("time", "time", FAINT, "answered", "ask", "clock"),
    ("ask ", "question", AMBER, "asked", "mark", None),
    ("open ", "open", MUTE, "opened", "open", None),
    ("return", "return", GREEN, "returned", "end", None),
    ("fail", "fail", RED, "failed", "end", None),
    ("stopped", "stop", RED, "broke", "stop", None),
    ("#", "comment", FAINT, "commented", "comment", None),
]
CHIP_BORDER = {"heard": VIOLET, "time": FAINT}  # otherwise the colour of the row's icon


def kind_of(text):
    return next(k for k in KINDS if text.startswith(k[0]))


def default_chip(text):
    """What the program wrote to get this row: `exec "make"` for `exec make → exit 0`."""
    word = text.split()[0].rstrip(":")
    if word == "exec":
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

    def mark(self, text, border, cy):
        """What the program does that needs no world: a chip, and one arrow to its mark in the log."""
        x0 = self.inner()[0]
        w = width(text, 12, mono=True) + 12
        self.out += [
            f'<rect x="{x0 + .5}" y="{cy - 9}" width="{n(w)}" height="18" rx="4" fill="{SOFT}" stroke="{border}"/>',
            label(x0 + 6.5, cy + 4, text, "ch"),
            arrow(x0 + w + 5, self.c.l0 - 4, cy + .5),
        ]

    def cut(self, y, note, keep=1):
        """A break: every frame inside the first `keep`, the session's, ends here, with no mark."""
        cut = self.stack[keep:]
        for _ in cut:
            self.close(y, closed=False)
        if cut:
            self.out.append(f'<path stroke="{RED}" d="M{cut[0]["x0"]},{y}H{cut[0]["x1"]}"/>')
        if cut and note:
            self.out.append(label(cut[0]["x0"] + PAD, y + 13, note, "s", RED))


def figure(name, title, rows, inside=(), takes=False, heads=False, legend=False, foot=(), workspace=None):
    """Write agent-api/`name`.svg. `inside`: the frames already open above the first row. `takes`: draw an
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
                program.open(r["frame"], y + 2.5, cy)
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
            elif role == "mark":
                program.mark(r.get("chip", "ask question"), color, cy)
            if r.get("note") and role in ("open", "ask", "mark"):
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
    head = [label(c.p0, 14, "computation", "s"), label(c.m0 + 6, 14, "carried out by", "s"), label(c.l0 + 7, 14, "log", "s")]
    if heads:
        head += [label(c.pos, 31, "position", "f", anchor="end"), label(c.frame, 31, "call", "f"),
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
             "the computation asks; the driver carries it out and appends the answer"),
            (arrow(x + 66, x, 0, dashed=True), "on replay the answer is read back from the log"),
            (arrow(x, x + 66, 0), "a mark of what the computation did: a call opened, a call ended"),
        ]
        for sample, text in samples:
            out.append(f'<g transform="translate(0,{y + 6.5})">{sample}</g>' + label(x + 78, y + 10, text, "s"))
            y += 17
    for line in foot:
        out.append(label(c.p0, y + 10, line, "s"))
        y += 16
    height = int(y + 6 if y > bottom + 10 else bottom + 8)

    frames = [svg for _, svg in sorted(program.boxes, key=lambda b: b[0])]  # outer boxes first
    write("agent-api", name, title, height, head + [panel] + frames + out)


# --- the figures of language.md, runtime.md and agents.md ----------------------------------------------------------


def SESSION(by=None):
    """The start of every log: the root, the call of the run, the session, its read and its opening."""
    root = R(0, "-", "the workspace the run starts from", **({"by": by} if by else {}))
    return [root, R(1, "-", "call session", **({"by": by} if by else {})),
            R(2, "-", "inbox: takes 1", chip="await"), R(3, "session", "open session")]


def CALLED(task="fix the build", program="agent"):
    """The start of every log: the session, a person's call of the agent, the session's read of it,
    and the opening of the call."""
    return SESSION() + [R(4, "-", f"call {program} “{task}”"), R(5, "session", "inbox: takes 4", chip="await"),
                        R(6, program, f"open {program}")]


figure("log", "The log of a small agent, beside its computation", CALLED() + [
    R(7, "agent", "inbox: nothing"),
    R(8, "agent", "sample → says “run make”"),
    R(9, "agent", "exec make → exit 0"),
    R(10, "agent", "return fixed", end='return "fixed"'),
], heads=True, legend=True)

figure("perform", "Three operations, each answered by its part of the world", [
    GAP(),
    R(7, "agent", "sample → says “run the tests”"),
    R(8, "agent", "exec pytest -q → exit 1"),
    R(9, "agent", "time 4 min 12 s of 1 h"),
    GAP(),
], inside=["session", "agent"])

figure("workspace", "The versions of the workspace along a log", [
    R(0, "-", "the workspace the run starts from", ws="w0"),
    R(1, "-", "call session"),
    R(3, "session", "open session"),
    R(4, "-", "call agent “fix the build”"),
    R(6, "agent", "open agent"),
    GAP(on="bash"),
    R(10, "bash", "exec make → exit 0", ws="w1", on="w0"),
    GAP(off=1),
    R(14, "-", "workspace changed: fixed Makefile", ws="w2"),
    GAP(on="bash#1"),
    R(17, "bash#1", "exec make test → exit 0", ws="w3", on="w2"),
    GAP(off=2),
    R(43, "-", "call grader “pytest /grader”"),
    R(45, "grader", "open grader"),
    R(46, "grader", "exec pytest /grader → exit 0", ws="w4", on="w3"),
], workspace="a grader’s command, too, leaves a version: its reports are in `w4`")

figure("inbox", "Notices arrive from outside, and reads take them", CALLED() + [
    R(7, "agent", "inbox: nothing", note="a read takes what has arrived, possibly nothing"),
    R(8, "agent", "sample → bash make"),
    GAP(),
    R(12, "-", "said “use ninja, not make”", by="at any time"),
    GAP(),
    R(15, "agent", "inbox: takes 12"),
    R(16, "agent", "sample → bash ninja"),
    GAP(),
    R(20, "agent", "inbox: nothing"),
    GAP(),
], takes=True)

figure("call", "Two calls of a routine, each a bracket in the log", CALLED() + [
    R(7, "step", "open step “make”"),
    R(8, "step", "exec make → exit 0"),
    R(9, "step", "return 0", end="return 0"),
    R(10, "step#1", "open step “make test”"),
    R(11, "step#1", "exec make test → exit 1"),
    R(12, "step#1", "return 1", end="return 1"),
    R(13, "agent", "return 2 steps, 1 failed"),
], foot=["a child frame is its caller’s and a step: the routine, and how many calls of it came before"])

figure("failure", "A failed sample ends its routine, and the caller catches the failure", CALLED() + [
    R(7, "planner", "open planner “ship it”"),
    R(8, "planner", "sample failed: the request is too long",
      note="the answer is an error: the operation fails where it was performed"),
    R(9, "planner", "fail: the request is too long"),
    NOTE("`try … catch`: the caller catches the error; no mark"),
    R(10, "step", "open step “make”"),
    R(11, "step", "exec make → exit 0"),
    R(12, "step", "return 0", end="return 0"),
    R(13, "agent", "return built without a plan"),
])

figure("loop", "A loop of three rounds: the log holds their events, flat", CALLED() + [
    ROUND("round 1 · state: 2 messages", 4),
    R(7, "agent", "sample → bash make"),
    R(8, "bash", "open bash “make”"),
    R(9, "bash", "exec make → exit 2"),
    R(10, "bash", "return exit 2: no rule to make target"),
    ROUND("round 2 · 4 messages", 4),
    R(11, "agent", "sample → bash ninja"),
    R(12, "bash#1", "open bash “ninja”"),
    R(13, "bash#1", "exec ninja → exit 0"),
    R(14, "bash#1", "return exit 0: build ok"),
    ROUND("round 3 · 6 messages → result", 1),
    R(15, "agent", "sample → says “fixed: use ninja”"),
    R(16, "agent", "return fixed: use ninja"),
], foot=["a loop writes nothing of its own; every round reads an event"])

figure("stop", "A break ends the call open in its frame, and the session waits for the next", SESSION() + [
    R(4, "-", "call agent “ship it”"),
    R(5, "session", "inbox: takes 4", chip="await"),
    R(6, "agent", "open agent"),
    R(7, "workflow", "open workflow “ship it”"),
    R(8, "planner", "open planner “ship it”"),
    R(9, "planner", "sample → lookup build"),
    R(10, "-", "stopped session/agent: to grade", note="the call and every call in it end; no marks"),
    DIV("the session's call failed: it waits for the next"),
    R(11, "-", "call grader “pytest /grader”"),
    R(12, "session", "inbox: takes 11", chip="await"),
    R(13, "grader", "open grader"),
    R(14, "grader", "exec pytest /grader → exit 1"),
    R(15, "grader", "return fail 12/48", end="return verdict"),
])

figure("routines", "The log of the workflow, its sub-agent and their tools", CALLED("ship it") + [
    R(7, "workflow", "open workflow “ship it”"),
    R(8, "planner", "open planner “ship it”"),
    R(9, "planner", "sample → lookup build"),
    R(10, "lookup", "open lookup “build”"),
    R(11, "lookup", "exec grep build notes.txt → exit 0"),
    R(12, "lookup", "return build: make"),
    R(13, "planner", "sample → says “make make test”"),
    R(14, "planner", "return steps: make, make test"),
    R(15, "step", "open step “make”"),
    R(16, "step", "exec make → exit 0"),
    R(17, "step", "return 0"),
    R(18, "step#1", "open step “make test”"),
    R(19, "step#1", "exec make test → exit 1"),
    R(20, "step#1", "return 1"),
    R(21, "workflow", "return 2 steps, 1 failed"),
    R(22, "agent", "return 2 steps, 1 failed"),
])

figure("tool-call", "A response that asks for two tools, and the two calls it becomes", [
    GAP(),
    R(10, "agent", "inbox: nothing"),
    R(11, "agent", "sample → bash make; bash make test", note="the response asks for two tools"),
    NOTE("each: check its arguments, then call the tool's routine, the agent's settings added"),
    R(12, "bash#2", "open bash “make”"),
    R(13, "bash#2", "exec make → exit 0"),
    R(14, "bash#2", "return exit 0: build ok"),
    R(15, "bash#3", "open bash “make test”"),
    R(16, "bash#3", "exec make test → exit 1"),
    R(17, "bash#3", "return exit 1: 1 test failed"),
    R(18, "agent", "inbox: nothing"),
    R(19, "agent", "sample → says “one test fails”", note="the next request holds both results"),
    GAP(),
], inside=["session", "agent"])

figure("ask-user", "A question: the tool asks, the run waits, a person replies, the call returns", [
    GAP(),
    R(10, "agent", "inbox: nothing"),
    R(11, "agent", "sample → ask_user Keep duplicates?"),
    R(12, "ask_user", "open ask_user “Keep duplicates?”"),
    R(13, "ask_user", "ask “Keep duplicates?”", note="the question is in the log, whoever asks it"),
    DIV("the driver stops: the run waits for a reply to session/agent/ask_user"),
    R(14, "-", "replied to session/agent/ask_user: yes", by="`alaya reply`"),
    R(15, "ask_user", "inbox: takes 14", chip="the reply"),
    R(16, "ask_user", "return yes", end='return "yes"'),
    R(17, "agent", "inbox: nothing", note="a plain read leaves replies"),
    R(18, "agent", "sample → bash sort -u names.txt", note="the model is shown `yes` as the tool’s result"),
    GAP(),
], inside=["session", "agent"], takes=True)

figure("run", "A whole run: the session, the agent, then a grader, each in a frame of its own", SESSION(by="`alaya new`") + [
    R(4, "-", "call mini-swe “Implement SPEC.md”", by="`alaya call`"),
    R(5, "session", "inbox: takes 4", chip="await"),
    R(6, "mini-swe", "open mini-swe"),
    GAP("the agent’s rounds"),
    R(44, "mini-swe", "return Submitted"),
    DIV("no call runs: the session waits for the next"),
    R(45, "-", "call grader “pytest /grader”", by="`alaya call`"),
    R(46, "session", "inbox: takes 45", chip="await"),
    R(47, "grader", "open grader"),
    R(48, "grader", "exec pytest /grader → exit 0"),
    R(49, "grader", "return pass 48/48", end="return verdict", note="the grader’s verdict"),
])


# === docs/llm-api.md ======================================================================
#
# Three figures, each drawn by its own function: a conversation, in the report's messages; who
# gets which draw of a request; and the cache of a request's draws. The parts come first.

LLM_STYLE = STYLE + f".r{{font-size:11px;font-weight:600;fill:{MUTE};letter-spacing:.04em}}"  # a role
CELL_W, CELL_H, PITCH = 40, 20, 76  # a draw's cell, and from one cell of a sequence to the next


def block(x, y, w, lines, mono=False, stroke=LINE):
    """A block of the report, `w` wide from (x, y) down: prose on white, or monospace on the
    soft ground. Its SVG and its height."""
    line_h, base = (17, 20) if mono else (20, 22)
    h = 16 + line_h * len(lines)
    svg = [f'<rect x="{n(x + .5)}" y="{n(y + .5)}" width="{n(w - 1)}" height="{h - 1}" rx="6" '
           f'fill="{SOFT if mono else "#fff"}" stroke="{stroke}"/>']
    svg += [label(x + 11, y + base + line_h * i, line, "ch" if mono else "") for i, line in enumerate(lines)]
    if max(width(line, 12 if mono else 13, mono) for line in lines) > w - 22:
        print(f"  a block may not hold: {lines}")
    return svg, h


def message(x, y, w, role, parts, new=False):
    """A message of a request as the report draws it: its role, a 2px bar at its left (blue when
    the request adds the message), and its parts, each `("label", text)`, `("prose", lines)` or
    `("code", lines)`. Its SVG and its height."""
    svg, top = [label(x + 14, y + 11, role, "r")], y
    y += 16
    for kind, body in parts:
        if kind == "label":
            svg.append(label(x + 14, y + 17, body, "s"))
            y += 22
        else:
            part, h = block(x + 14, y + 4, w - 14, body, kind == "code")
            svg += part
            y += 4 + h
    svg.append(f'<rect x="{n(x)}" y="{n(top)}" width="2" height="{n(y - top)}" fill="{BLUE if new else LINE}"/>')
    return svg, y - top


def messages(x, y, w, specs, new=False):
    """Messages one under another, each `(role, parts)`. Their SVG and where they end."""
    svg = []
    for role, parts in specs:
        part, h = message(x, y, w, role, parts, new)
        svg += part
        y += h + 10
    return svg, y - 10


def facts(x, y, pairs):
    """Facts as the report lists them, in small type: a grey name, its value in ink. Their SVG
    and their height."""
    at = x + max(width(name, 11) for name, _ in pairs) + 14
    svg = []
    for i, (name, value) in enumerate(pairs):
        svg += [label(x, y + 11 + 16 * i, name, "s"), label(at, y + 11 + 16 * i, value, "s n", INK)]
    return svg, 16 * len(pairs)


def cell(x, y, text, dashed=False):
    """A draw, a sampled response: a small block with the model's blue border, dashed when the
    draw is not there yet."""
    return (f'<rect x="{n(x + .5)}" y="{n(y + .5)}" width="{CELL_W - 1}" height="{CELL_H - 1}" rx="4" '
            f'fill="{"#fff" if dashed else SOFT}" stroke="{BLUE}"' + (' stroke-dasharray="3 2"' if dashed else "") + "/>"
            + label(x + CELL_W / 2, y + 14, text, "ch", anchor="middle"))


def sequence(x, y, names, missing=0):
    """The draws of a request in a row from (x, y); the last `missing` of them are not there yet."""
    return [cell(x + PITCH * i, y, name, dashed=i >= len(names) - missing) for i, name in enumerate(names)]


# --- the figures of llm-api.md ------------------------------------------------------------

SAYS = ("prose", ["Listing."])
CALLS = [("label", "calls bash · command"), ("code", ["ls"])]


def conversation():
    """A request, the response sampled for it, and the request after the tool has run."""
    columns = [(12, 200), (322, 220), (652, 256)]  # the left and the width of each
    (x1, w1), (x2, w2), (x3, w3) = columns
    heads = ["request", "response", "the next request"]
    out = [label(x, 14, head, "s") for (x, _), head in zip(columns, heads)]
    top, first = 26, 52  # of what a column says of the whole request; of its first message

    # the request: what it offers, then its messages
    part, _ = facts(x1, top + 3, [("tools", "bash")])
    out += part
    part, end1 = messages(x1, first, w1, [
        ("SYSTEM", [("prose", ["You can run bash."])]),
        ("USER", [("prose", ["List the files."])]),
    ])
    out += part

    # the response: one message, new, and what the provider says of it
    part, end2 = messages(x2, first, w2, [("ASSISTANT", [SAYS] + CALLS)], new=True)
    out += part
    part, h = facts(x2, end2 + 10, [("finish reason", "tool_calls"), ("usage", "in 212 · out 18")])
    out += part
    end2 += 10 + h

    # the next request: the messages before, folded, and the two it adds
    out.append(label(x3, top + 14, "2 earlier messages, as in the request before", "s"))
    part, end3 = messages(x3, first, w3, [
        ("ASSISTANT", [SAYS] + CALLS),
        ("TOOL · `c1`", [("code", ["a.txt", "b.txt"])]),
    ], new=True)
    out += part

    # from a column to the next, at the middle of the response's message
    cy = first + 58
    for (x, w), (to, _), text in zip(columns, columns[1:], ["sample", "the tool’s result is added"]):
        a, b = x + w + 10, to - 10
        lines = wrap(text, b - a - 8)
        out.append(arrow(a, b, cy + .5))
        out += [label((a + b) / 2 - 2, cy - 7 - LINE_H * (len(lines) - 1 - i), line, "s", anchor="middle")
                for i, line in enumerate(lines)]

    write("llm-api", "conversation", "A request, its response, and the next request, which adds the call and its result",
          int(max(end1, end2, end3)) + 10, out, LLM_STYLE)


def draws():
    """Two callers read two draws each of one request, in the order A, B, A, B: which draws each
    gets from a repeatable model and from an independent one. A caller's draws stand over (A) or
    under (B) the draws of the request they are, joined to them by a line."""
    panels = [
        ("Model.repeatable", "every stream reads the sequence from its start: the same question gets the same answers",
         {"A": [0, 1], "B": [0, 1]}),
        ("Model.independent", "all streams share one position: no two callers get the same draw",
         {"A": [0, 2], "B": [1, 3]}),
    ]
    names, ordinals = ["d0", "d1", "d2", "d3"], ["1st", "2nd"]
    text_w, rows_x, cells_x = 280, 350, 510  # the description's width; the rows' labels; the first cell
    band, out, y = 146, [], 4
    for i, (name, says, got) in enumerate(panels):
        if i:
            out.append(f'<path stroke="{LINE}" d="M12,{y - 6.5}H{WIDTH - 12}"/>')
        ya, yd, yb = y + 18, y + 54, y + 90  # the tops of the rows: caller A, the draws, caller B
        out.append(label(12, ya + 14, name, "ch"))
        out += [label(12, ya + 34 + LINE_H * j, line, "s") for j, line in enumerate(wrap(says, text_w))]
        out += [label(rows_x, ya + 14, "caller A", "s"), label(rows_x, yd + 14, "the draws of the request", "s"),
                label(rows_x, yb + 14, "caller B", "s")]
        out += sequence(cells_x, yd, names)
        out.append(label(cells_x + PITCH * len(names) - 8, yd + 14, "…", "f"))
        # a caller's draws: the row's top, the line to the draws' row, where `1st` and `2nd` stand
        for caller, y0, line, ordinal_y in [("A", ya, (ya + CELL_H, yd), ya - 5),
                                            ("B", yb, (yd + CELL_H, yb), yb + CELL_H + 12)]:
            for ordinal, draw in zip(ordinals, got[caller]):
                x = cells_x + PITCH * draw
                out += [f'<path class="a" d="M{x + CELL_W / 2},{line[0]}V{line[1]}"/>', cell(x, y0, names[draw]),
                        label(x + CELL_W / 2, ordinal_y, ordinal, "f", anchor="middle")]
        y += band
    write("llm-api", "draws", "Which draws of a request two callers get, from a repeatable model and from an independent one",
          y - 10, out, LLM_STYLE)


def cache():
    """A stream of a cached model asked for four draws when the cache holds three."""
    names, times = ["d0", "d1", "d2", "d3"], ["7.6 s", "3.1 s", "5.0 s", "4.2 s"]
    held = 3
    x, y = 190, 24  # of the first cell
    cy = y + CELL_H / 2
    out = [label(x, 14, "the cache entry of a request, on disk", "s")]
    out += sequence(x, y, names, missing=len(names) - held)
    out += [label(x + PITCH * i + CELL_W / 2, y + CELL_H + 13, time, "f n", anchor="middle") for i, time in enumerate(times)]

    # who asks, at the left; who answers what the cache does not hold, at the right
    ask = "stream.nextN 4"
    w = width(ask, 12, mono=True) + 12
    out += [f'<rect x="12.5" y="{cy - 9}" width="{n(w)}" height="18" rx="4" fill="{SOFT}" stroke="{GUIDE}"/>',
            label(18.5, cy + 4, ask, "ch"), arrow(12.5 + w + 6, x - 6, cy)]
    inside = "the model inside"
    w = width(inside) + 22
    last = x + PITCH * (len(names) - 1) + CELL_W
    out += [f'<rect x="{n(WIDTH - 12.5 - w)}" y="{cy - 13}" width="{n(w)}" height="26" rx="6" fill="{SOFT}" stroke="{BLUE}"/>',
            label(WIDTH - 12.5 - w + 11, cy + 4.5, inside), arrow(WIDTH - 12.5 - w - 6, last + 6, cy)]

    # under the cells: which of them are replayed, which are sampled
    by = y + CELL_H + 22
    groups = [(0, held, "replayed: no call to the provider", GREEN),
              (held, len(names), "missing: sampled from the model inside, timed, appended", BLUE)]
    for a, b, text, color in groups:
        x0, x1 = x + PITCH * a + .5, x + PITCH * (b - 1) + CELL_W - .5
        out += [f'<path class="a" d="M{x0},{by}v4H{x1}v-4"/>', label(x0, by + 18, text, "s", color)]
    out.append(label(12, by + 44, "the same model, request and index always give the same response", "s"))
    write("llm-api", "cache", "The cache of a request’s draws: three replayed, the fourth sampled and appended",
          int(by + 52), out, LLM_STYLE)


conversation()
draws()
cache()


# === docs/log-schema.md ===================================================================
#
# Two figures, each drawn by its own function: a log as it is stored, an entry for an event, with
# a fork; and what the grading of a run puts into the grader's container and takes out of it.

BAD = ("#f8dfdd", "#8a2a25")  # the tint of what went wrong: its ground, its text
CARD_H = 66                   # an entry's card


def card(x, y, w, name, glyph, text, took):
    """An entry: its name, its event as a row of the report, and the time the event took."""
    color = next(k[2] for k in KINDS if k[1] == glyph)
    if width(text) > w - 41:
        print(f"  a card may not hold: {text}")
    return [f'<rect x="{n(x + .5)}" y="{n(y + .5)}" width="{w - 1}" height="{CARD_H - 1}" rx="6" fill="#fff" stroke="{GUIDE}"/>',
            label(x + 11, y + 19, name, "fr"), icon(x + 11, y + 36, glyph, color),
            label(x + 30, y + 40.5, text, fill=VIOLET if color == VIOLET else None),
            label(x + w - 11, y + 57, took, "f n", anchor="end")]


def node(x, y, w, text, above=None, below=(), stroke=GUIDE):
    """A thing in a diagram: a block of one line of monospace, `w` wide from (x, y), a label
    above it and small grey lines below it. Its SVG and where it ends."""
    svg, h = block(x, y, w, [text], mono=True, stroke=stroke)
    if above:
        svg.append(label(x, y - 5, above, "s"))
    svg += [label(x, y + h + 14 + LINE_H * i, line, "s") for i, line in enumerate(below)]
    return svg, y + h + (6 + LINE_H * len(below) if below else 0)


def pill(x, cy, text, tint):
    """A chip of the report, how something ended: small type on a tint, its right end at `x`."""
    w = width(text, 11) + 16
    return (f'<rect x="{n(x - w)}" y="{n(cy - 9)}" width="{n(w)}" height="18" rx="9" fill="{tint[0]}"/>'
            + label(x - w / 2, cy + 4, text, "s n", tint[1], "middle")), w


def entries():
    """Three entries of a log, after its root and the call of its agent, and a second child of
    the last: a fork."""
    root = "… the call"
    line = [("06d9ae75ae21", "heard", "inbox: takes 1", "0.0 s"),
            ("b064afdd73b7", "open", "open mini-swe", "0.0 s"),
            ("8cb007600701", "heard", "inbox: nothing", "0.0 s")]
    children = [("draw 0", ("07d75e6a71ee", "sample", "sample → bash make", "7.6 s")),
                ("draw 1", ("9a11c0de42f7", "sample", "sample → bash ninja", "3.1 s"))]
    parent = "parent"
    named = ["name = SHA-256 of {parent, event}", "the time is no part of it"]
    fork = "two children of one entry: a fork"
    stored = "stored as `entries/<name>.<parent>.json`, one file an entry"

    w, gap, x0, top = 173, 46, 78, 22          # a card's width, between two cards, the first card
    xs = [x0 + (w + gap) * i for i in range(4)]
    cy = top + CARD_H / 2 + .5                 # the line of the parents
    out = [label(12, cy + 3.5, root, "fr"), arrow(x0 - 6, 12 + width(root, 11.5, mono=True) + 6, cy)]
    for i, (x, entry) in enumerate(zip(xs, line)):
        out += card(x, top, w, *entry)
        if i:
            out.append(arrow(x - 6, x - gap + 6, cy))
    out.append(label(xs[1] - gap / 2, cy - 6, parent, "s", anchor="middle"))

    # the children of the last entry of the line, one under another; the second branches off
    x, y = xs[3], top
    for i, (note, entry) in enumerate(children):
        out += [label(x, y - 5, note, "s")] + card(x, y, w, *entry)
        at = y + CARD_H / 2 + .5
        if i == 0:
            out.append(arrow(x - 6, x - gap + 6, cy))
        else:
            tx = x - gap / 2 + .5
            out.append(f'<path class="a" d="M{x - 6},{at}H{tx + 6}Q{tx},{at} {tx},{at - 6}V{cy + 6}Q{tx},{cy} {tx - 6},{cy}"/>')
        y += CARD_H + 27

    below = top + CARD_H + 16
    out += [label(xs[1], below + LINE_H * i, text, "s") for i, text in enumerate(named)]
    out.append(label(xs[2], below, fork, "s"))
    bottom = y - 27
    out.append(label(12, bottom - 4, stored, "s"))
    write("log-schema", "entries", "A log stored as entries, each named by the hash of its parent and its event, and a fork",
          int(bottom) + 8, out)


def grader():
    """The grading of a run: what goes into the grader's container, and what comes out of it."""
    heads = ["what goes in", "the grader runs", "what comes out"]
    inputs = [("the workspace at the graded entry", "the workspace", "the version the log has reached"),
              ("the grader’s image, pinned by its call", "trusted files: hidden tests", "built into the image")]
    container = "a container of the grader’s own image · no network"
    mounts = [("the workdir", "the workspace, read-write"), ("/grader", "in the image")]
    command = ("sh /grader/grade.sh", "the grader’s command, with a time limit")
    tap = ("stdout: TAP", ["1..3", "ok 1 - parses", "ok 2 - runs", "not ok 3 - errors"])
    read, verdict, says = "read as", "fail 2/3", ["the verdict:", "the value of the call"]
    kept = ["stderr, kept apart, and the exit status", "are kept, and decide nothing"]
    left = ("the workspace as the grader left it", "a new version", "its reports in it, after the agent’s last version")

    (x1, w1), (x2, w2), (x3, w3) = columns = [(12, 226), (282, 296), (622, 286)]
    top, pitch, inset = 26, 76, 14             # of the zones; from a row to the next; in the container
    rows = [top + 30 + pitch * i for i in range(3)]
    half = 17                                  # from a one-line block's top to its middle
    out = [label(x, 14, head, "s") for (x, _), head in zip(columns, heads)]

    # what goes in, and where it is mounted
    mount_w = max(width(name, 12, mono=True) for name, _ in mounts) + 22
    inside = []
    for y, (above, text, fact), (name, note) in zip(rows, inputs, mounts):
        out += node(x1, y, w1, text, above, [fact])[0]
        inside += node(x2 + inset, y, mount_w, name, below=[note])[0]
        inside.append(arrow(x1 + w1 + 6, x2 + inset - 6, y + half))
    part, end2 = node(x2 + inset, rows[2], width(command[0], 12, mono=True) + 22, command[0], below=[command[1]], stroke=TEAL)
    inside += part + [label(x2 + inset, top + 18, container, "s")]

    # what comes out: the lines of the result and the verdict read off them; what decides nothing; the checkout
    block_w = 150
    y = rows[0]
    part, h = block(x3, y, block_w, tap[1], mono=True, stroke=GUIDE)
    cy = y + h / 2 + .5
    chip, chip_w = pill(x3 + w3, cy, verdict, BAD)
    a, b = x3 + block_w + 6, x3 + w3 - chip_w - 6
    out += part + [label(x3, y - 5, tap[0], "s"), arrow(x2 + w2 + 6, x3 - 6, cy), arrow(a, b, cy), chip,
                   label((a + b) / 2 - 2, cy - 6, read, "s", anchor="middle")]
    out += [label(x3 + w3, cy + 24 + LINE_H * i, line, "s", anchor="end") for i, line in enumerate(says)]
    out += [label(x3, y + h + 18 + LINE_H * i, line, "s") for i, line in enumerate(kept)]
    y = rows[2]
    part, end3 = node(x3, y, block_w, left[1], left[0], wrap(left[2], w3))
    out += part + [arrow(x2 + w2 + 6, x3 - 6, y + half)]

    box = (f'<rect x="{x2 + .5}" y="{top + .5}" width="{w2 - 1}" height="{n(end2 + 6 - top)}" rx="6" '
           f'fill="{SIDE}" stroke="{GUIDE}"/>')
    write("log-schema", "grader", "How a point is graded: what goes into the grader’s container, and what comes out of it",
          int(max(end2 + 7, end3)) + 8, out[:3] + [box] + inside + out[3:])


entries()
grader()


# === docs/cli.md ==========================================================================
#
# Thirteen figures, one for a command or a group of commands: what the command does to the forest
# of entries. All are drawn with one kit: a strip of entries, each a chip in the report's words,
# a parent at the left of its child. A chip's state says what the command does with the entry.

CLI_STYLE = STYLE + ".c{font-size:12px}"  # a chip's text
SEL = "#dfe9f6"                           # the ground of what is new, and of what is read
OK, WAIT, NEUTRAL = ("#dcf1e2", "#1c5c33"), ("#fbe9cf", "#7a4a08"), ("#eceef1", "#454b53")  # tints, as BAD
CHIP_H, JOIN, GAP_W = 25, 12, 14          # an entry's chip; the line between two; a gap
DROP, STEP = 14.5, 28                     # under a chip: where a branch leaves it, where its row starts

# A chip's state → its border, whether the border is dashed, its ground, its text when not ink:
# there before; appended by the command; deleted by it; read by it; appended by the next run.
STATES = {"old": (GUIDE, False, "#fff", None), "new": (BLUE, False, SEL, None), "gone": (RED, True, "#fff", FAINT),
          "read": (GUIDE, False, SEL, None), "later": (GUIDE, True, "#fff", MUTE)}


def chip(x, y, text, state="old", entry=False, bare=False):
    """An entry, from (x, y): the icon of its event and what the report says of it. `entry`: it
    is the `ENTRY` the command is given, so named above it. `bare`: the icon alone. Its SVG and
    its width."""
    _, glyph, color, _, role, _ = kind_of(text)
    stroke, dashed, ground, ink = STATES[state]
    w = 29 if bare else int(27 + width(text, 12) + 9) + 1
    cy = y + CHIP_H / 2
    svg = [f'<rect x="{n(x + .5)}" y="{n(y + .5)}" width="{w - 1}" height="{CHIP_H - 1}" rx="6" fill="{ground}" '
           f'stroke="{stroke}"' + (' stroke-dasharray="3 2"' if dashed else "") + "/>",
           icon(x + 8, cy, glyph, FAINT if state == "gone" else color)]
    if not bare:
        svg.append(label(x + 27, cy + 4, text, "c", ink or (MUTE if role == "comment" else None)))
    if entry:
        at = x + w // 2 + .5
        svg += [label(at, y - 9, "ENTRY", "s m", anchor="middle"), f'<path class="a" d="M{n(at)},{y - 6}V{y}"/>']
    return svg, w


def strip(x, y, items, join=JOIN):
    """Entries in a row from (x, y), each the child of the one at its left and joined to it by a
    line. An item is a chip's text, the arguments of `chip` after its place, or `…`: a stretch
    of entries left out. `join`: the length of every line, or of each. The SVG, and the left
    and the right of each item."""
    joins = join if isinstance(join, list) else [join] * len(items)
    svg, at, cy = [], [], y + CHIP_H / 2
    for i, item in enumerate(items):
        if i:
            svg.append(f'<path class="a" d="M{n(x)},{cy}h{n(joins[i - 1])}"/>')
            x += joins[i - 1]
        if item == "…":
            svg += [dot(x + 3 + 4 * j, cy, .9, FAINT) for j in range(3)]
            w = GAP_W
        else:
            part, w = chip(x, y, *([item] if isinstance(item, str) else item))
            svg += part
        at.append((x, x + w))
        x += w
    if x > WIDTH - 12:
        print(f"  a strip may not fit: it ends at {n(x)}")
    return svg, at


def branch(x, y, to, dashed=False):
    """A line from under the chip at (x, y) down to a row at `to`: a second child of the entry.
    Its SVG and where the row starts."""
    cy = to + CHIP_H / 2
    return (f'<path class="a{" d" if dashed else ""}" d="M{x + DROP},{y + CHIP_H}V{cy - 6}'
            f'Q{x + DROP},{cy} {x + DROP + 6},{cy}H{x + STEP}"/>'), x + STEP


def tag(x, y, text, tint):
    """A chip of the report beside or under an entry's chip, from x, in a row at y. Its SVG and
    its width."""
    w = int(width(text, 11) + 16) + 1
    return pill(x + w, y + CHIP_H // 2, text, tint)[0], w


def note(x, y, text):
    """A small grey note beside the chip of a row at y."""
    return label(x, y + CHIP_H / 2 + 4, text, "s")


def under(x, y, text, limit=None):
    """A small grey note under a row at y, in lines of `limit` at most."""
    lines = wrap(text, limit) if limit else [text]
    return [label(x, y + CHIP_H + 15 + LINE_H * i, line, "s") for i, line in enumerate(lines)]


def versions(y, marks):
    """The versions of the workspace along a line at y: each of `marks` is where a version is
    left and its name."""
    svg = [f'<path class="a" d="M{n(marks[0][0])},{y}H{n(marks[-1][0])}"/>']
    for x, name in marks:
        svg += [dot(x, y, 3.5, "#fff", MUTE), label(x, y + 17, name, "s m", anchor="middle")]
    return svg


def middle(span):
    """The middle of a chip, on a pixel's centre."""
    return (span[0] + span[1]) // 2 + .5


def cli(name, title, height, parts):
    write("cli", name, title, height, parts, CLI_STYLE)


# --- the figures of cli.md ----------------------------------------------------------------

TOP = 24  # of a row with an `ENTRY` above it


def cli_new():
    """`new`: a directory becomes the root of a run."""
    x, w, top = 12, 104, 18
    out = node(x, top, w, "./project", "`PROJECT`")[0]
    cy = top + 16.5
    x0, y = 190, int(cy - CHIP_H / 2)
    part, at = strip(x0, y, [("the workspace", "new")])
    out += [arrow(x + w + 6, x0 - 6, cy)] + part + under(at[0][0], y, "a snapshot of `PROJECT`: the run waits for a call")
    cli("new", "new: a directory becomes the root of a run", y + CHIP_H + 26, out)


def cli_call():
    """`call`: a call of a program is appended, and the next resume opens it in a frame of its own."""
    y = TOP
    out, at = strip(12, y, [("the workspace", "old", True), ("call mini-swe “the task”", "new"),
                            ("inbox: takes 1", "later"), ("open mini-swe", "later"), ("inbox", "later"), "…"])
    out += under(at[1][0], y, "its configuration: the program with its model and task, the image by digest", 300)
    out.append(note(at[-1][1] + 12, y, "the next `resume`"))
    cli("call", "call: a call of a program is appended, and the next resume opens it in a frame of its own",
        y + CHIP_H + 38, out)


def cli_resume():
    """`resume`: entries are appended after the given one until the run stops in one of three ways."""
    y = TOP
    out, at = strip(12, y, ["…", ("call mini-swe", "old", True), ("inbox", "new"), ("open mini-swe", "new"),
                            ("sample", "new"), "…"])
    ends = [(OK, "no call runs", "exit 0 or 1; a grader: by verdict"), (WAIT, "waits for a person", "exit 3"),
            (NEUTRAL, "paused at a limit", "exit 4")]
    bx, pitch = at[-1][1] + 10.5, 24
    out.append(f'<path class="a" d="M{bx + 4},{y - pitch + 3.5}H{bx}V{y + pitch + 21.5}H{bx + 4}"/>')
    for i, (tint, text, says) in enumerate(ends):
        row = y + pitch * (i - 1)
        part, w = tag(bx + 10, row, text, tint)
        out += [part, note(bx + 10 + w + 8, row, says)]
        if bx + 18 + w + width(says, 11) > WIDTH - 12:
            print(f"  resume: may not fit: {says}")
    cli("resume", "resume: entries are appended after the given one until no call runs, a call waits, or a limit pauses it",
        y + pitch + 30, out)


def cli_tell():
    """`tell`: a message appended after an entry that already goes on is a fork."""
    y, below = TOP, TOP + CHIP_H + 12
    out, at = strip(12, y, ["…", ("sample → bash make", "old", True), "open bash", "…"])
    line, x = branch(at[1][0], y, below)
    part, fork = strip(x, below, [("said “look at the evaluator”", "new")])
    notes = max(at[-1][1], fork[-1][1]) + 16
    out += [line] + part + [note(notes, y, "`ENTRY` already goes on, so this is a fork"),
                            note(notes, below, "read at the agent’s next inbox, in the next run")]
    cli("tell", "tell: a message is appended after the given entry, on a fork when the entry already goes on",
        below + CHIP_H + 8, out)


def cli_commit():
    """`commit`: a directory is snapshotted, and the workspace moves to the snapshot."""
    y = TOP
    cy = y + CHIP_H / 2
    out = node(12, y - 4, 92, "./edited", "`DIR`")[0]
    x = 196
    part, at = strip(x, y, ["…", ("exec make → exit 1", "old", True), ("workspace changed: M src/eval.py", "new")])
    a, b = 12 + 92 + 6, x - 8
    out += [arrow(a, b, cy), label((a + b) / 2 - 2, cy - 6, "snapshot", "s", anchor="middle")] + part
    track = y + CHIP_H + 15.5
    marks = [(middle(at[1]), "w3"), (middle(at[2]), "w4")]
    out += versions(track, marks) + [label(marks[1][0] + 12, track + 4, "the workspace moves to a new version", "s")]
    cli("commit", "commit: a snapshot of a directory is appended as a change of the workspace", int(track) + 26, out)


def cli_reply():
    """`reply`: a reply is appended after the question it answers; the next run goes on from it."""
    y = TOP
    out, at = strip(12, y, ["…", "open ask_user", ("ask “keep duplicates?”", "old", True),
                            ("replied to session/mini-swe/ask_user: yes", "new"), ("inbox: takes it", "later"), ("return yes", "later")])
    below = y + CHIP_H + 3
    out += [tag(at[2][0], below, "waits for a reply", WAIT)[0], note(at[4][0], below, "the next resume goes on from the reply")]
    cli("reply", "reply: a reply is appended after the question that waits for it, and the next resume goes on from it",
        below + CHIP_H + 4, out)


def cli_stop():
    """`stop`: a stop is appended, and the call is over."""
    y = TOP
    out, at = strip(12, y, ["…", ("sample → bash make", "old", True), ("stopped: wrong approach", "new")])
    x = at[-1][1] + 10
    part, w = tag(x, y, "the call is over", NEUTRAL)
    out += [part, note(x + w + 10, y, "nothing in it goes on; the run waits for the next call")]
    cli("stop", "stop: a stop is appended after the given entry, and the call is over", y + CHIP_H + 8, out)


def cli_grade():
    """Grading: where the agent still runs, a stop on a fork; then a call of the grader, which
    resume opens and runs."""
    y, below = TOP, TOP + CHIP_H + 12
    out, at = strip(12, y, ["…", ("exec make test → exit 1", "old", True), "…", "return Submitted: done"])
    line, x = branch(at[1][0], y, below)
    part, fork = strip(x, below, [("stopped: to grade", "new"), ("call grader", "new")] +
                       [(text, "later") for text in ["open grader", "exec grade.sh", "return fail 12/48"]])
    verdict, w = tag(fork[-1][1] + 10, below, "exit 1", BAD)
    if fork[-1][1] + 10 + w > WIDTH - 12:
        print("  grade: the verdict may not fit")
    out += [line] + part + [verdict] + under(x, below, "`stop` and `call` append; `resume` runs the grader in its own frame")
    foot = below + CHIP_H + 41
    out.append(label(12, foot, "where no call runs, as after the agent's end: no stop, and the grader is called there", "s"))
    cli("grade", "grading: the agent is stopped, the grader is called, and resume runs its command and returns the verdict",
        foot + 9, out)


def cli_comment():
    """`comment`: an annotation hangs from an entry, and the log goes on past it."""
    y, below = TOP, TOP + CHIP_H + 12
    out, at = strip(12, y, ["…", ("exec make test → exit 1", "old", True), "sample → bash pytest -x", "…"])
    line, x = branch(at[1][0], y, below, dashed=True)
    part, hung = strip(x, below, [("# flaky test, see issue 12", "new")])
    out += [line] + part + [note(hung[-1][1] + 16, below, "an annotation: the log goes on as if it were not there")]
    cli("comment", "comment: an annotation is appended after the given entry, and the log goes on as if it were not there",
        below + CHIP_H + 8, out)


def cli_rm():
    """`rm`: an entry and everything after it are deleted."""
    y, below = 6, 6 + CHIP_H + 26
    out, at = strip(12, y, ["…", "sample → bash make", "…", "return pass 41/48"])
    line, x = branch(at[1][0], y, below)
    part, _ = strip(x, below, [("said “a note”", "gone", True), "…", ("return pass 45/48", "gone")])
    out += [line] + part + under(x, below, "`ENTRY` and everything after it are deleted, then the snapshots only they named")
    cli("rm", "rm: the given entry and everything after it are deleted", below + CHIP_H + 24, out)


def cli_rebase():
    """`rebase`: the log, up to where the original and the revised agent differ, copied into a
    new data directory, each entry of the copy under the entry it was made from."""
    y, below = TOP + 4, TOP + 4 + CHIP_H + 50
    source = [("the workspace", "read", False, True), ("open agent", "read", False, True), ("said “fix it”", "read"),
              ("# an old comment", "old"), ("exec make", "read"), ("exec make test", "old"), "…",
              ("return fail 12/48", "old", True)]
    out, at = strip(12, y, source)
    # The copy: each entry at the place of the one it is made from, and after the copy, the next run's.
    copy = [(("the workspace", "new", False, True), 0), (("open agent", "new", False, True), 1), (("said “fix it”", "new"), 2),
            (("# a new comment", "new"), 3), (("exec make", "new"), 4), (("# rebased from …", "new"), 5),
            (("exec make check", "later"), None)]
    joins, end = [], None
    for item, slot in copy:
        if end is not None:
            joins.append(at[slot][0] - end if slot is not None else JOIN)
        end = (at[slot][0] if slot is not None else end + joins[-1]) + chip(0, 0, *item)[1]
    if min(joins) < 6:
        print("  rebase: two chips of the copy may touch")
    part, made = strip(12, below, [item for item, _ in copy], joins)
    out += part
    out += [label(12, y - 9, "`D`, the original agent’s log, only read: in blue, what the revised agent makes too", "s"),
            label(12, below - 9, "`DIR`: what `rebase` writes; the log’s comments left out, the revised agent’s written", "s")]
    out += under(at[5][0], y, "the revised agent runs `make check` here: the copy ends", 300)
    out += under(made[-1][0], below, "the next `run`, in `DIR`")
    cli("rebase", "rebase: the log, up to where the two agents differ, is copied into a new data directory, where the revised agent goes on",
        below + CHIP_H + 24, out)


def cli_read():
    """`tree`, `log`, `show`, `waiting`: what each reads of one small forest."""
    line = ["the workspace", "call mini-swe", "open mini-swe", "sample", "…", "return pass 48/48"]
    bare, fork, waits = 3, 3, "ask “…?”"  # chips with no text; the entry that forks; its second child
    panels = [("tree", "the whole forest: runs, stretches, forks", set(range(7)), None),
              ("log ENTRY", "the path from the root to `ENTRY`", set(range(6)), 5),
              ("show ENTRY", "one entry in full; `--request` adds the request it answered", {3}, 3),
              ("waiting", "every entry where a question waits", {6}, None)]
    wide, high = 460, 112  # a panel
    out = [f'<path stroke="{LINE}" d="M12,{high + .5}H{WIDTH - 12}"/>']
    for k, (name, says, read, entry) in enumerate(panels):
        x, top = 12 + wide * (k % 2), 4 + (high + 8) * (k // 2)
        y, below = top + 40, top + 40 + CHIP_H + 10
        state = lambda i: "read" if i in read else "old"
        out += [label(x, top + 12, name, "ch"), label(x + width(name, 12, mono=True) + 12, top + 12, says, "s")]
        if x + width(name, 12, mono=True) + 12 + width(says, 11) > x + wide - 24:
            print(f"  read: may not fit: {says}")
        part, at = strip(x, y, [text if text == "…" else (text, state(i), i == entry, i < bare) for i, text in enumerate(line)])
        hang, at_x = branch(at[fork][0], y, below)
        out += part + [hang] + strip(at_x, below, [(waits, state(6))])[0]
    cli("read", "tree, log, show and waiting: what each reads of the forest", 2 * high + 8, out)


def cli_workspace():
    """`ls`, `cat`, `checkout`, `diff`: the workspace at an entry is the last version left at or
    before it."""
    y = TOP
    line = [("the workspace", "w0"), ("exec make", "w1"), ("workspace changed: M Makefile", "w2"),
            ("sample → bash make test", None), ("exec make test", "w3")]
    given = 3
    out, at = strip(12, y, [(text, "old", i == given) for i, (text, _) in enumerate(line)])
    track = y + CHIP_H + 15.5
    marks = [(middle(span), name) for span, (_, name) in zip(at, line) if name]
    out += versions(track, marks)

    # from the given entry back along the line to the version it has, and what that version is
    x, to, says = middle(at[given]), marks[2][0], "the workspace at `ENTRY`: the last version left at or before it"
    out += [f'<path class="a" style="stroke:{MUTE}" d="M{x},{y + CHIP_H}V{track - 6}Q{x},{track} {x - 6},{track}H{to + 9}"/>',
            f'<path fill="{MUTE}" d="M{to + 4.5},{track}l5,-2.5v5z"/>', label(to + 16, track + 17, says, "s")]
    if to + 16 + width(says, 11) > marks[3][0] - 16:
        print("  workspace: the note may not fit between two versions")

    # the two versions `diff` compares
    a, b, by = marks[1][0], marks[3][0], track + 24
    out += [f'<path class="a" d="M{a},{by}v4H{b}v-4"/>', label(a, by + 17, "A", "s m", anchor="middle"),
            label(b, by + 17, "B", "s m", anchor="middle")]

    commands = [("`ls ENTRY src`, `cat ENTRY src/a.py`", "read from the snapshot, without restoring it"),
                ("`checkout ENTRY ./dir`", "writes the files into a directory"),
                ("`diff A B`", "the paths that differ between two entries’ versions")]
    says = 12 + max(width(command, 12) for command, _ in commands) + 16
    y = by + 34
    for i, (command, text) in enumerate(commands):
        out += [label(12, y + 12 + 18 * i, command, "c"), label(says, y + 12 + 18 * i, text, "s")]
    cli("workspace", "ls, cat, checkout and diff: the workspace at an entry is the last version left at or before it",
        int(y) + 18 * len(commands) + 4, out)


cli_new()
cli_call()
cli_resume()
cli_tell()
cli_commit()
cli_reply()
cli_stop()
cli_grade()
cli_comment()
cli_rm()
cli_rebase()
cli_read()
cli_workspace()
