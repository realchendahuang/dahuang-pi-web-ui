import type { TemplateResult } from "lit";
import {
	Archive,
	Bot,
	Box,
	Check,
	ChevronDown,
	ChevronRight,
	CircleStop,
	FileCode2,
	FileDiff,
	FolderOpen,
	FolderPlus,
	GitBranch,
	Globe,
	HardDrive,
	Keyboard,
	Languages,
	ListTodo,
	MessageSquare,
	Moon,
	Package,
	Paperclip,
	Plus,
	RefreshCw,
	Search,
	Send,
	Settings,
	Sparkles,
	Square,
	Sun,
	Terminal,
	Trash2,
	X,
} from "lucide";
import { renderLucideIcon, type LucideIconOptions } from "./lucideIcon";

export type AppIconName =
	| "archive"
	| "bot"
	| "box"
	| "check"
	| "chevronDown"
	| "chevronRight"
	| "close"
	| "context"
	| "diff"
	| "file"
	| "folder"
	| "folderPlus"
	| "git"
	| "globe"
	| "keyboard"
	| "language"
	| "list"
	| "machine"
	| "message"
	| "moon"
	| "package"
	| "paperclip"
	| "plus"
	| "refresh"
	| "search"
	| "send"
	| "settings"
	| "sparkles"
	| "stop"
	| "stopFilled"
	| "sun"
	| "terminal"
	| "trash";

const ICONS = {
	archive: Archive,
	bot: Bot,
	box: Box,
	check: Check,
	chevronDown: ChevronDown,
	chevronRight: ChevronRight,
	close: X,
	context: Sparkles,
	diff: FileDiff,
	file: FileCode2,
	folder: FolderOpen,
	folderPlus: FolderPlus,
	git: GitBranch,
	globe: Globe,
	keyboard: Keyboard,
	language: Languages,
	list: ListTodo,
	machine: HardDrive,
	message: MessageSquare,
	moon: Moon,
	package: Package,
	paperclip: Paperclip,
	plus: Plus,
	refresh: RefreshCw,
	search: Search,
	send: Send,
	settings: Settings,
	sparkles: Sparkles,
	stop: CircleStop,
	stopFilled: Square,
	sun: Sun,
	terminal: Terminal,
	trash: Trash2,
} as const satisfies Record<AppIconName, typeof Settings>;

export function appIcon(
	name: AppIconName,
	options?: LucideIconOptions,
): TemplateResult {
	return renderLucideIcon(ICONS[name], options);
}
