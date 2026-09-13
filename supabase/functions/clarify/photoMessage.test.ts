// The clarify chat attaches the user's photo to the model's first message so
// it can read the work item's attributes off the image instead of asking.
//
// Added 2026-09-12: the photo used to arrive only as a text note describing
// whatever the recognition step had picked as the subject — for "replace the
// metal trim above the sliding door" the note described the DOOR, so the chat
// asked about the door. With the image attached, the model takes the work item
// from the user's words and reads the trim's attributes from the photo.

import { assert, assertEquals } from "jsr:@std/assert@1";
import {
  buildModelMessages,
  MAX_PHOTO_CHARS,
  sanitizePhoto,
} from "./photoMessage.ts";

const turns = [
  { role: "user", content: "Replace metal trim above sliding door" },
  { role: "assistant", content: "About how long is the trim?" },
  { role: "user", content: "Not sure" },
] as { role: "user" | "assistant"; content: string }[];

Deno.test("no photo -> messages pass through as plain strings", () => {
  const out = buildModelMessages(turns, null);
  assertEquals(out.length, 3);
  for (const m of out) assert(typeof m.content === "string");
  assertEquals(out[0].content, "Replace metal trim above sliding door");
});

Deno.test("photo attaches to the first user message as an image block", () => {
  const out = buildModelMessages(turns, {
    data: "abc123",
    media_type: "image/jpeg",
  });
  const first = out[0].content;
  assert(Array.isArray(first), "first message content should be blocks");
  assertEquals(first.length, 2);
  assertEquals(first[0], {
    type: "image",
    source: { type: "base64", media_type: "image/jpeg", data: "abc123" },
  });
  assertEquals(first[1], {
    type: "text",
    text: "Replace metal trim above sliding door",
  });
  // Later turns stay plain text — the image rides only on the first message.
  assert(typeof out[1].content === "string");
  assert(typeof out[2].content === "string");
});

Deno.test("photo never attaches to a non-user first message", () => {
  const out = buildModelMessages(
    [{ role: "assistant", content: "hi" }],
    { data: "abc123", media_type: "image/jpeg" },
  );
  assert(typeof out[0].content === "string");
});

Deno.test("sanitizePhoto rejects missing, non-string, and oversized photos", () => {
  assertEquals(sanitizePhoto(undefined, "image/jpeg"), null);
  assertEquals(sanitizePhoto("", "image/jpeg"), null);
  assertEquals(sanitizePhoto(123, "image/jpeg"), null);
  assertEquals(sanitizePhoto("x".repeat(MAX_PHOTO_CHARS + 1), "image/jpeg"), null);
  assertEquals(sanitizePhoto("x".repeat(MAX_PHOTO_CHARS), "image/jpeg") !== null, true);
});

Deno.test("sanitizePhoto keeps valid photos, whitelists media types", () => {
  assertEquals(sanitizePhoto("abc123", "image/png"), {
    data: "abc123",
    media_type: "image/png",
  });
  // Unknown media type falls back to jpeg rather than failing the turn.
  assertEquals(sanitizePhoto("abc123", "image/tiff"), {
    data: "abc123",
    media_type: "image/jpeg",
  });
  assertEquals(sanitizePhoto("abc123", undefined), {
    data: "abc123",
    media_type: "image/jpeg",
  });
});
