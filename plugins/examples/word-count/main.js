// A read command makes this same count available to panels, plugins and AI.
nib.commands.register("dev.nib.wordcount.count", async (p, ctx) => {
  const c = await ctx.execute("query.context");
  const page = p.page || (c.page && c.page.ref);
  if (!page) return {page: null, pageNumber: null, words: 0};
  const {blocks} = await ctx.execute("recognize.pageText", {page});
  const text = (blocks || []).map(b => b.text || "").join(" ").trim();
  // Count words rather than punctuation. Unicode letters keep accented and non-Latin text intact.
  const words = (text.match(/[\p{L}\p{N}]+(?:['’\-][\p{L}\p{N}]+)*/gu) || []).length;
  return {page, pageNumber: c.page && c.page.ref === page ? c.page.index + 1 : null, words};
});
nib.commands.register("dev.nib.wordcount.show", async (p, ctx) => {
  await ctx.execute("panel.open", {id: "dev.nib.wordcount.panel"});
  const count = await ctx.execute("dev.nib.wordcount.count", {});
  nib.ui.postToPanel("dev.nib.wordcount.panel", count);
  return count;
});
let pending = null;
let generation = 0;
function refresh() {
  const ticket = ++generation;
  clearTimeout(pending);
  pending = setTimeout(async () => {
    try {
      const count = await nib.commands.execute("dev.nib.wordcount.count", {});
      if (ticket === generation) nib.ui.postToPanel("dev.nib.wordcount.panel", count);
    } catch (e) {
      if (ticket === generation) nib.ui.postToPanel("dev.nib.wordcount.panel", {error: e.message || "Unable to count this page"});
    }
  }, 200);
}
["tx.committed", "page.changed", "session.document", "doc.closed"].forEach(type => nib.events.on(type, refresh, {self: true}));
// The panel asks for an initial count on every open, including opens through panel.open.
nib.events.on("plugin.message", e => {
  const payload = e.payload || {};
  if (e.panel === "dev.nib.wordcount.panel" && payload.type === "refresh") refresh();
});
