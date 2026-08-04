import { createReadStream, type ReadStream } from "node:fs";
import { open, stat } from "node:fs/promises";
import { extname } from "node:path";
import type { PiWebPathAccessConfig, WorkspaceImagePreviewResponse } from "../../shared/apiTypes.js";
import { MAX_IMAGE_PREVIEW_BYTES, MAX_IMAGE_PREVIEW_LABEL } from "../../shared/workspaceFiles.js";
import { resolveWorkspacePathAccessTarget } from "./pathAccessPolicy.js";

const IMAGE_MIME_TYPES: Record<string, string | undefined> = {
  ".avif": "image/avif",
  ".bmp": "image/bmp",
  ".gif": "image/gif",
  ".ico": "image/x-icon",
  ".jpeg": "image/jpeg",
  ".jpg": "image/jpeg",
  ".png": "image/png",
  ".svg": "image/svg+xml",
  ".webp": "image/webp",
};

export interface WorkspaceImagePreview {
  path: string;
  mimeType: string;
  size: number;
  modifiedAt: string;
  stream: ReadStream;
}

interface ResolvedWorkspaceImagePreview {
  target: string;
  path: string;
  mimeType: string;
  size: number;
  modifiedAt: string;
}

export function imageMimeTypeForPath(path: string): string | undefined {
  return IMAGE_MIME_TYPES[extname(path).toLowerCase()];
}

export async function readWorkspaceImagePreview(rootPath: string, path: string | undefined, pathAccess?: PiWebPathAccessConfig): Promise<WorkspaceImagePreview> {
  const { target, ...preview } = await resolveWorkspaceImagePreview(rootPath, path, pathAccess);
  return {
    ...preview,
    stream: createReadStream(target),
  };
}

/**
 * Returns the same bounded image preview as the browser streaming route, but
 * serialized for the private Native Contract. The source path is resolved and
 * size-checked before bytes are read; callers must not expose a raw file URL
 * to the Swift client.
 */
export async function readWorkspaceImagePreviewData(
  rootPath: string,
  path: string | undefined,
  pathAccess?: PiWebPathAccessConfig,
): Promise<WorkspaceImagePreviewResponse> {
  const preview = await resolveWorkspaceImagePreview(rootPath, path, pathAccess);
  const bytes = await readBoundedImageBytes(preview.target);
  return {
    path: preview.path,
    mimeType: preview.mimeType,
    size: bytes.size,
    modifiedAt: bytes.modifiedAt,
    data: bytes.data.toString("base64"),
  };
}

async function resolveWorkspaceImagePreview(
  rootPath: string,
  path: string | undefined,
  pathAccess?: PiWebPathAccessConfig,
): Promise<ResolvedWorkspaceImagePreview> {
  if (path === undefined || path === "") throw new Error("path query parameter is required");
  const { target, displayPath } = await resolveWorkspacePathAccessTarget(rootPath, path, pathAccess);
  const s = await stat(target);
  if (!s.isFile()) throw new Error("Path is not a file");
  const mimeType = imageMimeTypeForPath(displayPath);
  if (mimeType === undefined) throw new Error("Image preview is not supported for this file type");
  if (s.size > MAX_IMAGE_PREVIEW_BYTES) throw new Error(`Image is too large to preview (limit ${MAX_IMAGE_PREVIEW_LABEL})`);
  return {
    target,
    path: displayPath,
    mimeType,
    size: s.size,
    modifiedAt: s.mtime.toISOString(),
  };
}

/** Read from an already resolved image descriptor so a replacement after the
 * initial path/size check cannot turn the JSON/base64 route into an unbounded
 * allocation. */
async function readBoundedImageBytes(target: string): Promise<{
  data: Buffer;
  size: number;
  modifiedAt: string;
}> {
  const handle = await open(target, "r");
  try {
    const metadata = await handle.stat();
    if (!metadata.isFile()) throw new Error("Path is not a file");
    if (metadata.size > MAX_IMAGE_PREVIEW_BYTES) {
      throw new Error(`Image is too large to preview (limit ${MAX_IMAGE_PREVIEW_LABEL})`);
    }
    const buffer = Buffer.alloc(metadata.size);
    if (buffer.length > 0) {
      const { bytesRead } = await handle.read(buffer, 0, buffer.length, 0);
      return {
        data: buffer.subarray(0, bytesRead),
        size: metadata.size,
        modifiedAt: metadata.mtime.toISOString(),
      };
    }
    return { data: buffer, size: metadata.size, modifiedAt: metadata.mtime.toISOString() };
  } finally {
    await handle.close();
  }
}
