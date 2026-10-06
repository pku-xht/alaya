// Prints tap-parser's final results for each fixture, reduced to what Alaya.Base.Tap models.
// Regenerate Test/Base/Tap/expected.json with tap-parser 18.3.4 (tapjs commit 8ab84eb):
//   npm install tap-parser@18.3.4 && node Test/Base/Tap/oracle.js Test/Base/Tap/fixtures > Test/Base/Tap/expected.json
const fs = require('fs')
const path = require('path')
const { Parser } = require('tap-parser')

const dir = process.argv[2]
const out = {}
for (const name of fs.readdirSync(dir).filter(f => f.endsWith('.tap')).sort()) {
  const text = fs.readFileSync(path.join(dir, name), 'utf8')
  const p = new Parser()
  const points = []
  p.on('assert', r => points.push({ ok: r.ok, id: r.id, name: r.name,
    todo: r.todo === false ? null : r.todo === true ? '' : r.todo,
    skip: r.skip === false ? null : r.skip === true ? '' : r.skip }))
  p.on('complete', r => {
    out[name] = {
      ok: r.ok, count: r.count, pass: r.pass, todo: p.todo, skip: p.skip,
      bailout: r.bailout === false ? null : r.bailout === true ? '' : r.bailout,
      plan: r.plan.end === null ? null :
        { start: r.plan.start, end: r.plan.end, skipAll: r.plan.skipAll, reason: r.plan.comment },
      points,
    }
  })
  p.end(text)
}
process.stdout.write(JSON.stringify(out, null, 1) + '\n')
