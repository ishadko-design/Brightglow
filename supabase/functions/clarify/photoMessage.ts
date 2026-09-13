// Photo → model message plumbing for the clarify chat.
//
// The app may attach the user's photo (base64) to any clarify turn. The model
// then reads the work item's attributes (material, size, count, scope) off the
// image itself — the photo becomes an input alongside the user's words, instead
// of the chat having to ask questions a picture could have answered.
//
// Kept in its own module so it can be unit-tested without importing index.ts
// (which starts Deno.serve on import).

export interface TextTurn {
  role: "user" | "assistant";
  content: string;
}

export type PhotoMediaType =
  | "image/jpeg"
  | "image/png"
  | "image/webp"
  | "image/gif";

export interface ImageBlock {
  type: "image";
  source: { type: "base64"; media_type: PhotoMediaType; data: string };
}

export interface TextBlock {
  type: "text";
  text: string;
}

export interface ModelMessage {
  role: "user" | "assistant";
  content: string | (ImageBlock | TextBlock)[];
}

const ALLOWED_MEDIA_TYPES: ReadonlySet<PhotoMediaType> = new Set([
  "image/jpeg",
  "image/png",
  "image/webp",
  "image/gif",
]);

/// ~8M chars of base64 ≈ 6 MB of JPEG — far above the ~200 KB the app sends
/// (768px, JPEG 0.7). Anything bigger is dropped so a bad client can't stuff
/// the request.
export const MAX_PHOTO_CHARS = 8_000_000;

export interface SanitizedPhoto {
  data: string;
  media_type: PhotoMediaType;
}

const isPhotoMediaType = (s: string): s is PhotoMediaType =>
  (ALLOWED_MEDIA_TYPES as ReadonlySet<string>).has(s);

/// Validate the raw `photo` / `media_type` payload fields. Returns null when
/// there is no usable photo (absent, wrong type, or absurdly large) — the
/// caller then proceeds exactly as before, on the text note alone.
export function sanitizePhoto(
  photo: unknown,
  mediaType: unknown,
): SanitizedPhoto | null {
  if (
    typeof photo !== "string" || photo.length === 0 ||
    photo.length > MAX_PHOTO_CHARS
  ) {
    return null;
  }
  const media_type =
    typeof mediaType === "string" && isPhotoMediaType(mediaType)
      ? mediaType
      : "image/jpeg";
  return { data: photo, media_type };
}

/// Build the messages array for the model. When a photo is present it is
/// attached to the FIRST user message as an image block ahead of the text.
/// Every turn re-attaches it: the function is stateless and the app resends
/// the full history each call, so later turns can also answer visually
/// ("is the trim painted or bare metal?"). A first message that isn't from
/// the user never gets the image — that would be someone else's words.
export function buildModelMessages(
  turns: TextTurn[],
  photo: SanitizedPhoto | null,
): ModelMessage[] {
  return turns.map((t, i) => {
    if (i === 0 && photo && t.role === "user") {
      const imageBlock: ImageBlock = {
        type: "image",
        source: {
          type: "base64",
          media_type: photo.media_type,
          data: photo.data,
        },
      };
      const textBlock: TextBlock = { type: "text", text: t.content };
      return { role: t.role, content: [imageBlock, textBlock] };
    }
    return { role: t.role, content: t.content };
  });
}
