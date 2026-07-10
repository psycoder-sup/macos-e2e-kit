// Adds an item via the Add button and verifies both the UI (row/count) and the app's own state op.
export const name = "add item via Add button";

export default async ({ d, expect, log }) => {
  // Observe: input present, and Add starts disabled because the input is empty.
  await d.waitForNode("demo.input");
  const initial = await d.tree();
  expect.disabled(initial, "demo.add");

  // Act: type an item; the Add button should enable.
  await d.type("First item", "demo.input");
  await d.waitForNode("demo.add", { enabled: true });

  // Act: press Add, then wait for the list/count to reflect exactly one item.
  await d.perform("demo.add");
  await d.waitFor(
    async () => {
      const t = await d.tree();
      const row = d.find(t, "demo.row.0");
      const count = d.find(t, "demo.count");
      return row || (count && String(count.value ?? "").startsWith("1 ")) || false;
    },
    { desc: "list/count reflects 1 item" }
  );

  // Cross-check against the app's side-channel state op (authoritative, AX-independent).
  const state = await d.call("demo.state");
  expect(state).toEqual(["First item"]);
  log('added one item; demo.state == ["First item"]');
};
