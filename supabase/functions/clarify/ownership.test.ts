import { assertEquals } from "jsr:@std/assert@1";
import { asksOwnership, impliesOwned, projectDetails } from "./ownership.ts";

Deno.test("impliesOwned: install/hook-up verbs, not buy", () => {
  assertEquals(impliesOwned("Install 9kw outdoor sauna for 4"), true);
  assertEquals(impliesOwned("hook up my new hot tub"), true);
  assertEquals(impliesOwned("buy and install a sauna"), false);
  assertEquals(impliesOwned("I want a sauna in the backyard"), false);
});

Deno.test("asksOwnership catches the variants seen live", () => {
  for (const q of [
    "Do you already have the sauna unit, or is it on order?",
    "Is the sauna already purchased, or still being bought/built?",
    "Do you already have the sauna kit or unit, or still need to buy one?",
  ]) assertEquals(asksOwnership(q), true, q);
  assertEquals(asksOwnership("How far is the sauna from your electrical panel?"), false);
  assertEquals(asksOwnership("Is your panel 100A or 200A?"), false);
});

Deno.test("projectDetails rebuilds an empty project scope", () => {
  const spec = { complexity: "project", components: ["permit", "240V circuit", "trench"] };
  assertEquals(projectDetails("", "outdoor sauna install", spec, true),
    "project: outdoor sauna install (unit already purchased, not included); includes: permit, 240V circuit, trench");
  assertEquals(projectDetails("project: x; includes: y", "t", spec, true), "project: x; includes: y");
  assertEquals(projectDetails("1 panel", "breaker swap", { complexity: "task" }, false), "1 panel");
});
