// Every read and edit uses the caller's command context and undo group.
nib.commands.register("dev.nib.hello.stamp", async (p, ctx) => {
  const c = await ctx.execute("query.context");
  const page = p.page || (c.page && c.page.ref);
  if (!page) throw {code: "invalid_params", message: "Open a page first", path: "$.page", hint: "Open a notebook or supply a page ref."};
  const r = await ctx.execute("text.createBox", {
    page, id: p.id, frame: [48, 48, 320, 40], text: "Hello from a plugin 👋"
  });
  nib.ui.toast("Stamped " + r.ref);
  return r;
});
