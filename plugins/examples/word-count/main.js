const panelID = "dev.nib.wordcount.panel";
// A read command makes this same count available to panels, plugins and AI.
nib.commands.register("dev.nib.wordcount.count", async (p, ctx) => {
  const c = await ctx.execute("query.context");
  const page = p.page || (c.page && c.page.ref);
  if (!page) return {page: null, pageNumber: null, words: 0};
  const {blocks} = await ctx.execute("recognize.pageText", {page});
  const text = (blocks || []).map(b => b.text || "").join(" ").trim();
  // Segment scripts without spaces and preserve combining marks in the fallback.
  const words = typeof Intl !== "undefined" && typeof Intl.Segmenter === "function"
    ? Array.from(new Intl.Segmenter(undefined, {granularity: "word"}).segment(text)).filter(s => s.isWordLike).length
    : (text.match(/[\p{L}\p{M}\p{N}]+(?:['’\-][\p{L}\p{M}\p{N}]+)*/gu) || []).length;
  return {page, pageNumber: c.page && c.page.ref === page ? c.page.index + 1 : null, words};
});
nib.commands.register("dev.nib.wordcount.show", async (p, ctx) => {
  await ctx.execute("panel.open", {id: panelID});
  open = true;
  return refresh(0);
});
let open = false;
let pending = null;
let generation = 0;
let lastDocument = null;
function refresh(delay = 800) {
  if (!open) return;
  const ticket = ++generation;
  clearTimeout(pending);
  const run = async () => {
    try {
      const c = await nib.commands.execute("query.context", {});
      if (ticket !== generation || !open) return;
      lastDocument = c.document && c.document.ref ? c.document.ref.replace(/^doc:/, "") : null;
      const count = await nib.commands.execute("dev.nib.wordcount.count", {});
      const current = await nib.commands.execute("query.context", {});
      if (ticket === generation && open && count.page === ((current.page && current.page.ref) || null)) nib.ui.postToPanel(panelID, count);
      return count;
    } catch (e) {
      if (ticket === generation && open) nib.ui.postToPanel(panelID, {error: e.message || "Unable to count this page"});
    }
  };
  if (!delay) return run();
  pending = setTimeout(run, delay);
}
nib.events.on("tx.committed", e => {
  if (e.doc !== lastDocument) return;
  refresh();
}, {self: true});
["page.changed", "session.document", "doc.closed"].forEach(type => nib.events.on(type, () => refresh(), {self: true}));
// The panel reports its visibility on every open and close, including panel.open.
nib.events.on("plugin.message", e => {
  const payload = e.payload || {};
  if (e.panel !== panelID) return;
  if (payload.type === "refresh") { open = true; refresh(); }
  if (payload.type === "closed") { open = false; ++generation; clearTimeout(pending); }
});
