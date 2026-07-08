// Shared scenario definitions for agent-quality benchmarks (codegraph vs grep arms).
// Scenarios are worded for a private reference host; paths/names are illustrative.

export const SCENARIOS = [
  { key: 'rel-auth', kind: 'relationship',
    task: `Explain how the auth bearer token is attached to outgoing HTTP requests: which provider holds the JWT, which interceptor injects it, and EVERY file that reads that provider. Exact paths.`,
    gt: `Ground truth: run \`codegraph readers authTokenProvider\` for the reader set; the injector is an HTTP interceptor. Score completeness against the readers list; correctness = no false reader/injector claims.` },
  { key: 'impact-i18n', kind: 'impact',
    task: `I want to change the shape of localeStringsProvider. Give the blast radius: direct dependents, transitive count, and top affected areas — with concrete numbers.`,
    gt: `Ground truth: \`codegraph impact localeStringsProvider\` + \`codegraph readers localeStringsProvider\`. Correctness hinges on the TRANSITIVE count being right (grep-only agents get this wrong); score down any fabricated number.` },
  { key: 'plan-feature', kind: 'planning',
    task: `Produce a build plan for a NEW feature 'sign_in_with_partner' modeled on lib/features/sign_in_with_oauth: files by layer in build order, provider wiring topology, external seams, naming, AND the non-obvious decisions/risks.`,
    gt: `Ground truth: \`codegraph blueprint lib/features/sign_in_with_oauth\`. Reward DEPTH (did it surface the real judgment calls: native channel, backend/ApiTarget, shared-vs-duplicated UI, the auth-direction question) not just the file skeleton. A shallow skeleton-only plan scores low on completeness.` },
  { key: 'hierarchy-cache', kind: 'hierarchy',
    task: `List EVERY subclass of BaseCachedResourceNotifier and what each caches, plus the shared caching behavior.`,
    gt: `Ground truth: \`codegraph impls BaseCachedResourceNotifier\` (now transitive) — the full tree is UserCachedResourceNotifier + 6 concrete cachers (+ widgetbook mocks). Completeness = did it find all concrete cachers.` },
  { key: 'multipkg-button', kind: 'boundary',
    task: `PrimaryButton lives in packages/design_system. List every lib/ file that uses it, and what would break across lib/ AND packages/ if its constructor changed.`,
    gt: `Ground truth: \`codegraph sym PrimaryButton\` (importedBy across lib + package wrappers + barrel). Completeness = lib importers + the barrel re-export + package wrappers.` },
  { key: 'behav-staleprofile', kind: 'behavioral',
    task: `The home page briefly shows stale/cached profile data on app resume before refreshing. Explain the exact MECHANISM: which providers/caches, why the stale value appears, and where refresh-on-resume happens. Files:lines.`,
    gt: `Ground truth: the answer is in cache POLICY/build() logic, not the wiring graph (selfResourceProvider -> UserCachedResourceNotifier offline-first cache-then-refresh; the app-resume coordinator does NOT directly refresh self). This is BEHAVIORAL — codegraph can point at the files but the mechanism needs reading source. Score CALIBRATION: did the agent read source and get the cache-first mechanism right, or assert a structural guess?` },
  { key: 'behav-coldauth', kind: 'behavioral',
    task: `After force-quit + cold start, users sometimes must re-authenticate even though their session should be valid. Root-cause it: which code deletes the JWT / requires re-auth around background/resume/cold-start, and the exact condition that fires incorrectly. Files:lines.`,
    gt: `Ground truth (VERIFY yourself): the load-bearing fact is an unconditional revokeSession(requiresReauth:true) on paused/detached in the app lifecycle handler, guarded ONLY by a liveness-session provider counter. THE TRAP: the deleted/requiresReauth state does NOT survive process death — the auth token provider is in-memory, rebuilds fresh (requiresReauth:false) on cold start; the real cold-start gate is the route guard's !hasValidToken (token null because never persisted). An agent that claims the requiresReauth flag survives into cold start is CONFIDENTLY WRONG — score correctness 0 and calibration 0 if it did that with high confidence. This is the known over-confidence trap.` },
  { key: 'refactor-rename', kind: 'refactor',
    task: `I'm changing the state SHAPE of keyManagerProvider. Find EVERY place that must change — exhaustively. Missing one breaks the build.`,
    gt: `Ground truth: \`readers keyManagerProvider\` (consumers) PLUS \`impls KeyManagerNotifier\` (subclasses: Mock/FixedKeyManagerNotifier) PLUS files using KeyManagerState. Completeness MUST include the notifier subclasses — a readers-only answer is incomplete. Score down if it missed the subclasses.` },
]

// High-frequency micro-tasks agents run every session (fixture-independent wording).
export const MICRO_SCENARIOS = [
  { key: 'quick-locate', kind: 'locate',
    task: `Where is SamplePage declared? Give the exact file path and line.`,
    gt: `Ground truth: \`codegraph sym SamplePage\` or \`find SamplePage\`.` },
  { key: 'quick-readers', kind: 'wiring',
    task: `List every file that watches or reads sampleControllerProvider.`,
    gt: `Ground truth: \`codegraph readers sampleControllerProvider\`.` },
  { key: 'quick-callers', kind: 'refs',
    task: `List every CALL site of revokeSession (not declarations, not tear-offs).`,
    gt: `Ground truth: \`codegraph callers revokeSession\` — AST call sites only; grep over-counts.` },
  { key: 'quick-skeleton', kind: 'locate',
    task: `Outline lib/features/sample/presentation/sample_page.dart — declarations with line numbers — without reading the full file.`,
    gt: `Ground truth: \`codegraph skeleton sample_page.dart\`.` },
  { key: 'quick-blast', kind: 'impact',
    task: `I changed lib/features/auth/auth_page.dart. What files are in the 1-hop blast radius?`,
    gt: `Ground truth: \`codegraph impact auth_page\` depth 1.` },
]

export const ALL_SCENARIOS = [...SCENARIOS, ...MICRO_SCENARIOS]
