import { svg, type TemplateResult } from "lit";
import type { IconNode } from "lucide";

export interface LucideIconOptions {
	className?: string;
	size?: number;
	strokeWidth?: number;
}

/**
 * Render a Lucide `IconNode` as a Lit SVG template.
 * Matches Lucide defaults: 24 viewBox, currentColor stroke, round caps.
 */
export function renderLucideIcon(
	icon: IconNode,
	options: LucideIconOptions = {},
): TemplateResult {
	const className = options.className ?? "lucide-icon";
	const size = options.size ?? 16;
	const strokeWidth = options.strokeWidth ?? 2;
	return svg`
    <svg
      class=${className}
      width=${String(size)}
      height=${String(size)}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width=${String(strokeWidth)}
      stroke-linecap="round"
      stroke-linejoin="round"
      aria-hidden="true"
      focusable="false"
    >
      ${icon.map((node) => renderIconNode(node))}
    </svg>
  `;
}

type IconNodeEntry = IconNode[number];

function renderIconNode(node: IconNodeEntry): TemplateResult {
	const [tag, attrs] = node;
	switch (tag) {
		case "path":
			return svg`<path d=${attrString(attrs, "d")} fill=${attrString(attrs, "fill", "none")}></path>`;
		case "circle":
			return svg`<circle cx=${attrString(attrs, "cx")} cy=${attrString(attrs, "cy")} r=${attrString(attrs, "r")} fill=${attrString(attrs, "fill", "none")}></circle>`;
		case "rect":
			return svg`<rect x=${attrString(attrs, "x")} y=${attrString(attrs, "y")} width=${attrString(attrs, "width")} height=${attrString(attrs, "height")} rx=${attrString(attrs, "rx", "0")} ry=${attrString(attrs, "ry", attrString(attrs, "rx", "0"))} fill=${attrString(attrs, "fill", "none")}></rect>`;
		case "line":
			return svg`<line x1=${attrString(attrs, "x1")} y1=${attrString(attrs, "y1")} x2=${attrString(attrs, "x2")} y2=${attrString(attrs, "y2")}></line>`;
		case "polyline":
			return svg`<polyline points=${attrString(attrs, "points")} fill=${attrString(attrs, "fill", "none")}></polyline>`;
		case "polygon":
			return svg`<polygon points=${attrString(attrs, "points")} fill=${attrString(attrs, "fill", "none")}></polygon>`;
		case "ellipse":
			return svg`<ellipse cx=${attrString(attrs, "cx")} cy=${attrString(attrs, "cy")} rx=${attrString(attrs, "rx")} ry=${attrString(attrs, "ry")} fill=${attrString(attrs, "fill", "none")}></ellipse>`;
		default:
			return svg``;
	}
}

function attrString(
	attrs: Record<string, unknown>,
	key: string,
	fallback = "",
): string {
	const value = attrs[key];
	if (typeof value === "string") return value;
	if (typeof value === "number" || typeof value === "boolean")
		return String(value);
	return fallback;
}
