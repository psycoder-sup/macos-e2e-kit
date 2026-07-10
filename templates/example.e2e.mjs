// Copy this file into tests/e2e/smoke.e2e.mjs when onboarding a new app (see skills/e2e-setup).
// One file = one test scenario. runner.mjs runs every tests/e2e/*.e2e.mjs against a single running
// app instance, in order, and reports PASS/FAIL per file (FAIL also saves a screenshot + tree.json).

// Optional per-file overrides (both have runner defaults if omitted):
// export const name = "human-readable test name";   // shown in PASS/FAIL output (default: filename)
// export const timeout = 60000;                       // ms before this test is FAILed as a timeout

export default async ({ d, expect, artifacts, log }) => {
  // Observe: read the current UI as an accessibility tree.
  const tree = await d.tree();

  // Assert something you expect to already be on screen, then act on it.
  // expect.node(tree, "my.button");
  // await d.perform("my.button");             // AXPress
  // await d.type("hello world", "my.input");  // real key events (updates bindings)
  // await d.key("return", ["command"]);       // named key + modifiers

  // Re-observe: wait for the UI to reflect the action, then assert the result.
  // const result = await d.waitForNode("my.result");
  // expect(result.value).toBe("hello world");

  log("smoke test ran — replace with real assertions for your app");
};
