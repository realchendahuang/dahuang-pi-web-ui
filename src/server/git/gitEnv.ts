const GIT_LOCAL_ENV_VARS = [
  "GIT_ALTERNATE_OBJECT_DIRECTORIES",
  "GIT_COMMON_DIR",
  "GIT_DIR",
  "GIT_INDEX_FILE",
  "GIT_OBJECT_DIRECTORY",
  "GIT_PREFIX",
  "GIT_QUARANTINE_PATH",
  "GIT_WORK_TREE",
];

export function sanitizedGitEnv(env: NodeJS.ProcessEnv = process.env): NodeJS.ProcessEnv {
  const blocked = new Set<string>(GIT_LOCAL_ENV_VARS);
  // The long-lived Runtime has no interactive terminal. Prevent a Git command
  // from hanging forever for credentials; a future Keychain broker will be the
  // explicit credential boundary for native Git actions.
  return {
    ...Object.fromEntries(Object.entries(env).filter(([key]) => !blocked.has(key))),
    GIT_TERMINAL_PROMPT: "0",
  };
}
