// Exercises the keyboard paths: ⌘Return adds the typed item, Escape clears the input.
export const name = "keyboard: ⌘Return adds, Escape clears";

export default async ({ d, expect, artifacts, log }) => {
  await d.waitForNode("demo.input");

  // ⌘Return fires the Add button's key equivalent — the typed item is appended.
  await d.type("Second", "demo.input");
  await d.key("return", ["command"]);
  await d.waitFor(
    async () => {
      const state = await d.call("demo.state");
      return Array.isArray(state) && state.includes("Second");
    },
    { desc: '⌘Return added "Second"' }
  );

  // Escape fires the Clear button's key equivalent — the input is emptied.
  await d.type("Discard me", "demo.input");
  await d.waitForNode("demo.input", { enabled: true });
  await d.key("escape");
  const cleared = await d.waitFor(
    async () => {
      const t = await d.tree();
      const input = d.find(t, "demo.input");
      if (!input) return undefined;
      return input.value === "" || input.value == null ? input : undefined;
    },
    { desc: "Escape cleared the input" }
  );
  expect(cleared.value === "" || cleared.value == null).toBeTruthy();

  // Capture at least one screenshot into the runner's artifacts dir.
  await d.shot("keyboard", artifacts || ".");
  log("⌘Return added an item; Escape cleared the input");
};
