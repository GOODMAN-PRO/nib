// Translations: args {root: <i18n folder with in/<locale>/NN.json chunks from extract_strings.py --export-missing>, locales: [{code, language, required, all, chunks}]}; outputs out/<locale>/NN.json, qa/<locale>.json; then build {locale: {key: value}} and run extract_strings.py --import. Checker: tools/fleet/i18n-check.py.
export const meta = {
  name: 'nib-i18n',
  description: 'Translate the 1471 new Nib UI strings into 14 locales (10 chunks per locale) with per-locale mechanical + language QA and a redo pass for flagged keys',
  phases: [
    { title: 'Translate', detail: 'one agent per locale chunk writes out/<locale>/<nn>.json and runs check.py' },
    { title: 'QA', detail: 'one reviewer per locale: check.py + language/terminology review -> qa/<locale>.json' },
    { title: 'Redo', detail: 'one fixer per locale rewrites the flagged keys until check.py is clean' },
  ],
}
const A = args
const LOCALES = A.locales
const ROOT = A.root
const WROOT = ROOT.replace(/\//g, '\\')
const M = 'sonnet'
const T_SCHEMA = { type: 'object', properties: { written: { type: 'boolean' }, keys: { type: 'number' }, missingKeys: { type: 'array', items: { type: 'string' } }, notes: { type: 'string' } }, required: ['written', 'keys', 'missingKeys', 'notes'] }
const QA_SCHEMA = { type: 'object', properties: { checked: { type: 'number' }, redo: { type: 'array', items: { type: 'object', properties: { key: { type: 'string' }, chunk: { type: 'string' }, reason: { type: 'string' } }, required: ['key', 'chunk', 'reason'] } }, notes: { type: 'string' } }, required: ['checked', 'redo', 'notes'] }
const R_SCHEMA = { type: 'object', properties: { fixed: { type: 'number' }, remaining: { type: 'array', items: { type: 'string' } }, notes: { type: 'string' } }, required: ['fixed', 'remaining', 'notes'] }

const RULES = (L) => `Rules:
- Match Apple's own ${L.language} terminology for iPadOS (Settings, Files, VoiceOver, Apple Pencil, Undo, Redo, Share, Trash, Favorites, Recents, Markup, Zoom...). Menu and button titles stay short, in the style Apple uses in ${L.language}. Keep sentence case where the English uses it.
- Keep every format specifier exactly (%@, %lld, %lf, %d, %.1f, %%). When the word order needs it, use positional forms (%1$@, %2$lld) for ALL specifiers of that string. Keep \\n line breaks, quotes, "…", leading/trailing spaces and separators such as " · ".
- Keys that contain exactly one integer count specifier (%lld, %d, %ld, %u) get an OBJECT with the plural forms ${JSON.stringify(L.required)} instead of a string (${L.all.join(', ')} are the allowed categories; use the exact spelling). Every other key gets a plain string.
- Keep product and brand names as they are: Nib, Apple Pencil, iCloud Drive, OneDrive, Dropbox, Google Drive, WebDAV, PDF, Markdown, LaTeX, MCP, Ollama, LM Studio, OpenRouter, Anthropic, Claude, OpenAI, ChatGPT, GIPHY, Image Playground, AirPrint, VoiceOver, Tailscale, AltStore, SideStore, Goodnotes, GIF, PNG, JPEG, CSV, JSON, QR, URL. A value that is only such names, symbols or specifiers is returned unchanged.
- Translate everything else; never leave an English sentence untranslated, never translate or alter the keys, never add or drop keys.`

const translatePrompt = (L, nn) => `You translate the user interface of Nib, a handwriting note-taking app for iPad and iPhone (like Goodnotes), from English into ${L.language} (locale ${L.code}).
INPUT: read ${ROOT}/in/${L.code}/${nn}.json fully. It is a JSON object {key: {comment, locales, value}}; the key is the English text and "value" repeats it.
OUTPUT: write ${WROOT}\\out\\${L.code}\\${nn}.json with the Write tool (UTF-8): ONE JSON object mapping every input key to its translation.
${RULES(L)}
VERIFY: run in Bash: python -X utf8 -I ${ROOT}/check.py ${L.code} ${nn}
It prints "errors" (missing keys, specifier mismatches, plural form gaps, empty values, unexpected keys) and "check" items (values identical to the English). Fix every error and every "check" item that is not a confirmed brand/technical term, rewrite the file, and run it again until errors is 0. Return written=true, keys = number of keys in your file, missingKeys = keys you could not translate (normally none), notes = terminology decisions worth knowing.`

const qaPrompt = (L) => `Quality review of the ${L.language} (${L.code}) UI translations of Nib (a handwriting note-taking app for iPad and iPhone) in ${ROOT}/out/${L.code}/*.json; the English sources are in ${ROOT}/in/${L.code}/*.json (same file names; each "value" is the English text).
1. Run: python -X utf8 -I ${ROOT}/check.py ${L.code}   Every problem with severity "error" goes into redo; every "check" item goes into redo unless the value is only a brand or technical term.
2. Read every output file against its input. Flag for redo any translation that: is in the wrong language or script; leaves English words that are not brand names; mistranslates the UI meaning (Trash is the Files-style folder, Undo/Redo, Lasso, Highlighter, Eraser, Zoom Window, Study set, Flashcard, Whiteboard, Notebook, Text document, Outline, Bookmark, Layer, Template, Sticky note, Tape, Ruler, Laser pointer, Presentation mode, Read-only, Password lock, Backup, Sync, Bridge, Plugin, Assistant); uses a register different from Apple's ${L.language} iPadOS UI; breaks or reorders a specifier incorrectly; or translates a recurring term differently from the other files (choose Apple's term and flag the outliers).
3. Write ${WROOT}\\qa\\${L.code}.json with the Write tool: {"redo": [{"key": ..., "chunk": "<file name such as 03.json>", "reason": ...}]} (an empty list when clean). Return the same list and checked = total keys reviewed. Do not modify the out files yourself.`

const redoPrompt = (L) => `Fix the flagged ${L.language} (${L.code}) UI translations of Nib. Read ${ROOT}/qa/${L.code}.json: each entry names a key, its chunk file in ${ROOT}/out/${L.code}/ and the reason. Write a small Python script (run with python -X utf8 -I) that loads each chunk file, replaces only the flagged values with your corrected translations, and saves it back (ensure_ascii=False, indent=1); keep every other key untouched.
${RULES(L)}
Then run python -X utf8 -I ${ROOT}/check.py ${L.code} and fix until errors is 0 and only acceptable identical brand/term values remain. Return fixed = number of keys corrected, remaining = keys you could not fix, notes.`

phase('Translate')
const results = await pipeline(LOCALES,
  (L) => parallel(L.chunks.map((nn) => () => agent(translatePrompt(L, nn), { label: `translate:${L.code}/${nn}`, phase: 'Translate', model: M, schema: T_SCHEMA })))
    .then((rs) => ({ L, translate: rs })),
  (r) => agent(qaPrompt(r.L), { label: `qa:${r.L.code}`, phase: 'QA', model: M, schema: QA_SCHEMA }).then((qa) => ({ ...r, qa })),
  (r) => (r.qa && r.qa.redo.length
      ? agent(redoPrompt(r.L), { label: `redo:${r.L.code}`, phase: 'Redo', model: M, schema: R_SCHEMA })
      : Promise.resolve({ fixed: 0, remaining: [], notes: r.qa ? 'nothing flagged' : 'QA agent returned nothing' }))
    .then((redo) => ({
      locale: r.L.code,
      chunksDone: r.translate.filter(Boolean).filter((t) => t.written).length,
      keysWritten: r.translate.filter(Boolean).reduce((a, t) => a + (t.keys || 0), 0),
      missing: r.translate.filter(Boolean).flatMap((t) => t.missingKeys || []),
      qaFlagged: r.qa ? r.qa.redo.length : null,
      redo,
    })))
const done = results.filter(Boolean)
log(`i18n: ${done.length}/${LOCALES.length} locales processed; ${done.reduce((a, r) => a + r.keysWritten, 0)} keys written; ${done.reduce((a, r) => a + (r.qaFlagged || 0), 0)} flagged by QA; ${done.reduce((a, r) => a + (r.redo.remaining || []).length, 0)} still open`)
return results