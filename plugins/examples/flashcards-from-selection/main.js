nib.commands.register("dev.nib.cards.fromSelection", async (p, ctx) => {
  const c = await ctx.execute("query.context");
  const refs = p.selection || (c.selection && c.selection.refs) || [];
  if (!refs.length) throw {code: "invalid_params", message: "Select some notes first", path: "$.selection", hint: "Select handwriting or text containing term — definition lines."};
  const sep = p.separator !== undefined ? p.separator : (nib.plugin.settings.separator || "—");
  if (typeof sep !== "string" || !sep.trim()) throw {code: "invalid_params", message: "The separator must not be empty", path: "$.separator", hint: "Use — or another delimiter."};
  const {text} = await ctx.execute("recognize.items", {refs});
  // Split at the first delimiter so definitions can themselves contain it.
  const pairs = String(text || "").split(/\r?\n/).map(line => {
    const i = line.indexOf(sep);
    return i < 0 ? null : [line.slice(0, i).trim(), line.slice(i + sep.length).trim()];
  }).filter(pair => pair && pair[0] && pair[1]);
  if (!pairs.length) throw {code: "invalid_params", message: "No complete flashcard pairs were found", path: "$.selection", hint: "Write one term — definition pair per line."};
  if (pairs.length > 500) throw {code: "invalid_params", message: "Select at most 500 flashcards at a time", path: "$.selection", hint: "Split the selection into smaller sets."};
  if (p.ids && (p.ids.length !== pairs.length || new Set(p.ids).size !== p.ids.length || p.ids.some(id => !/^[A-Za-z0-9_-]{1,64}$/.test(id)))) {
    throw {code: "invalid_params", message: "Supply one unique id per card", path: "$.ids", hint: "Use 1–64 letters, numbers, underscores or hyphens."};
  }
  const set = await ctx.execute("doc.create", {kind: "studySet", id: p.id,
    title: p.title || ((c.document && c.document.title) || "Selection") + " — cards"});
  for (let i = 0; i < pairs.length; i++) {
    await ctx.execute("card.add", {doc: set.ref, id: p.ids && p.ids[i], front: {text: pairs[i][0]}, back: {text: pairs[i][1]}});
  }
  nib.ui.toast("Made " + pairs.length + " cards");
  return {set: set.ref, cards: pairs.length};
});
