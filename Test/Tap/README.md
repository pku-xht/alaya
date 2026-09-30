# TAP parser test data

`fixtures/` holds the TAP streams from tap-parser's test suite
(<https://github.com/tapjs/tapjs/tree/8ab84eb1daae6dedbfcf07b8e0bf2c2a965ad81f/src/parser/test/fixtures>),
unchanged. tap-parser is node-tap's TAP parser, written by the author of the TAP 14
specification, and is licensed under the Blue Oak Model License 1.0.0
(<https://blueoakcouncil.org/license/1.0.0>).

`expected.json` is tap-parser's result for each fixture, reduced by `oracle.js` to what
`Alaya.Tap` models. To regenerate it:

```sh
npm install tap-parser@18.3.4
node Test/Tap/oracle.js Test/Tap/fixtures > Test/Tap/expected.json
```

`Test/Tap.lean` compares `Alaya.Tap.parse` with these results, and lists the fixtures where the
two differ on purpose.
