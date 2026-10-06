import Alaya.Core.Computation

/-! Frames in tests, written as `Frame.render` writes them: `⟪"agent", "bash#1"⟫` is the frame
`agent/bash#1`, the second call of `bash` by the call of `agent`. It expands to the array of its
segments, so it is a pattern as well as a term. -/

namespace Testing

open Lean

/-- `⟪"agent", "bash#1"⟫`: a frame by its steps, each a routine's name and, after `#`, how many
calls of that name its caller made before; `⟪⟫` is the run's own. -/
syntax "⟪" str,* "⟫" : term

macro_rules
  | `(⟪ $steps,* ⟫) => do
    let segments ← steps.getElems.mapM fun step => do
      let (name, occurrence) ← match step.getString.splitOn "#" with
        | [name] => pure (name, 0)
        | [name, occurrence] => match occurrence.toNat? with
          | some occurrence => pure (name, occurrence)
          | none => Macro.throwErrorAt step s!"a frame step counts its calls with a number: {step.getString}"
        | _ => Macro.throwErrorAt step s!"not a frame step: {step.getString}"
      `(Alaya.Core.Frame.Segment.mk $(Syntax.mkStrLit name) $(Syntax.mkNumLit (toString occurrence)))
    `(#[$segments,*])

end Testing
