# codegraph — code review

_Review of v0.9.3. Focus: big issues and wrong ideas, not style. Line refs are approximate._

## Overall

This is genuinely well-engineered work. It uses the real Dart analyzer parser, freezes its
wire format byte-for-byte, keeps the build deterministic, ships 172 test cases, and documents
its rejected ideas in the CHANGELOG. The design discipline is above average.

But the tool's headline promise is *"a resolved graph you can trust instead of grepping —
missing edges are fine, wrong edges are blockers."* Two silent-wrong-edge classes and one
scope problem break that promise **in exactly the cases where an agent would otherwise have
been correct by grepping**. That is the throughline of everything below: the tool is most
dangerous precisely where it claims to add the most value.

The good news: the hardest part (the provider ambiguity resolver) is already done correctly.
Most of the top issues are "apply that same pattern to the places that skipped it."

---

## Big issues / wrong ideas

### 1. The core "never a wrong edge" claim is violated by class-name resolution

The provider resolver (`_ProviderResolver`) is careful: a name declared in >1 file becomes one
node per declaration, and a reader only resolves if reachability narrows it to exactly one — else
it refuses. That is the right design.

The **class registry does none of this.** It is first-wins by bare class name, with no
ambiguity detection and no reachability gate:

- `engine.dart` ~976: `classRegistry.putIfAbsent(c.name, () => c)` — first file parsed wins.
- `engine.dart` ~1233: `implements/extends` edges resolve a supertype *name* to that first-wins file.
- `nav_resolution.dart` ~592: `navigates-to` page resolution trusts `classRegistry[pageTypeName]`.

Two concrete silent failures:

- **Type graph / `impls`:** two features each declaring `class State` (or any shared name) →
  the extends/implements edge points at whichever was parsed first. `impls` inherits it, and
  additionally never follows `with` (mixin application) at all, so `impls SomeMixin` misses
  `class X with SomeMixin` despite claiming "every subtype, transitive."
- **Navigation:** the path→route half is beautifully gated (constant substitution, uniqueness,
  shadowing refusals). Then the route→page half throws that away: `GoRoute(builder: (c,s) =>
  HomePage())` resolves `HomePage` first-wins. Two features with `class HomePage` → the nav edge
  points at the **wrong file**, with a fully "resolved" ✓ next to it.

This is the common Flutter pattern (`HomePage`, `DetailPage`, `SettingsPage` per feature). The
doctrine says wrong edges are blockers; these are confident, undisclosed wrong edges.

**Fix:** give classes the same treatment providers already get — detect ambiguous class names,
emit per-declaration nodes, gate on reachability, refuse when not unique.

### 2. Modern Riverpod (`@riverpod` codegen) is invisible — and unacknowledged

The **only** provider-detection path is a regex for provider-kind constructors in top-level
variable initializers (`engine.dart` ~635). The now-recommended idiom —

```dart
@riverpod
Future<User> user(Ref ref) => ...;   // generates userProvider into user.g.dart
```

— declares the real `userProvider` in a `.g.dart` file, which is **explicitly excluded** from
parsing. The annotated function is not a provider-kind top-level variable, so:

- `userProvider` never becomes a node.
- `ref.watch(userProvider)` resolves as `external: true` — treated like a third-party provider.
- `find`, `brief`, `readers` (declaration side), `unused`, and the declaration line/type are all
  broken for that provider.

There is **no annotation handling anywhere in `lib/`, no test for it, and zero mention in 885
lines of CHANGELOG** — which suggests it may not be a conscious trade-off. On a codegen-based
app the tool silently misses most or all providers, i.e. its entire deep value. At minimum this
needs a loud, up-front caveat ("manual provider declarations only"); ideally, detect `@riverpod`
and synthesize the `xProvider`/`xNotifierProvider` node from the annotated element.

### 3. Fitted to one codebase, marketed as general

The comments repeatedly hard-code one app's conventions — "routing/*_routes.dart",
`AppPaths.<...>` constant chains, `GoRoute` as the only route constructor, and the `_page.dart`
/ `_controller.dart` / `/view/` role rules. These are reasonable heuristics for that app, but on
a codebase with different idioms (auto_route, go_router with a different path-constant shape,
different file naming) the deep features quietly resolve nothing while still printing confident
output. The README's "works on any Dart/Flutter codebase" is true only for the shallow generic
graph; the parts that justify the tool are narrower than they read.

### 4. "Every call site" is name-matching, and its one safety net is dead for methods

`callers`/`refs`/`callchain` match by bare method name — they cannot distinguish two methods
named `delete()` on different types, and can't see dynamic dispatch. That's an honest limitation
of syntax-only, and it's disclosed in prose. **But the disclosure is gated behind a check that
never fires for methods:** `callers.dart` ~135 builds the "N declarations" note from top-level
`SymbolRec.name` only, and methods live in `SymbolRec.members` as rendered strings, not as named
symbols. So for any method query the multi-declaration warning (~172) is silently skipped, and
two unrelated `delete()` methods are unioned into one "callers of delete — N call sites" list
that reads as authoritative. The caveat is absent exactly when it's needed.

Related: `callchain` hazard flags (`unawaited`, `try`/swallow) are set by a `RecursiveAstVisitor`
that descends into nested closures, so a hazard inside a callback is attributed to the enclosing
method. And a bare un-awaited `Future` (the common fire-and-forget) is not flagged at all, while
the JSON legend presents these flags as authoritative.

---

## Smaller correctness / soundness issues

- **`find` can't see a class's 13th+ member.** `renderMembers` caps members at 12 and appends
  `"… N more"`; `find`'s member loop iterates only that capped list, so `find <member>` returns
  "(no matches)" for later members — read as "doesn't exist," the exact false-negative the
  feature exists to prevent. It also parses `"… 5 more"` into a phantom member named `more`.
- **`--json` truncates silently on `find` and `sym`.** Sibling verbs (`impls`, `readers`,
  `wiring`, `untested`, `impact`, `diff`) set a `truncated` field; `find`/`sym` do `.take(budget)`
  / `.take(5)` with no signal, so a JSON consumer treats a partial list as complete.
- **`diff` blast radius is computed from the last-built graph, not the working tree.** The change
  set comes from live `git diff` but areas/importers/reader-counts/"deleted but still imported"
  come from the committed `code_graph.json`. If the graph wasn't rebuilt, the blast radius is
  stale-wrong with no freshness guard — a silently-wrong result under a normal edit workflow.
- **Multi-package determinism.** `_localPackages()` iterates `Directory('packages').listSync()`
  in filesystem order (unsorted). Node/edge emission order and class-collision winners then depend
  on that order, so two machines can produce different `code_graph.json` for the same source →
  `check()` CI false-failures on monorepos. `lib/` files themselves are sorted; only the
  cross-package ordering is exposed. Sort `packages/*` too.
- **Ambiguous-provider in-degree is split across two keys.** `_buildInDeg` counts edges to both
  the per-declaration id (`provider:name@file`) and the unresolved bare id (`provider:name`), so
  reader counts and every "sort by in-degree" ranking under-count ambiguous providers.
- **`init` overclaims marker safety.** Comments say a marker inside a fenced code block is safe;
  the whole-line `^<!-- codegraph:begin -->$` anchor still matches it, so `upgrade` can rewrite
  user documentation that quotes the markers inside a fence. `.gitignore` idempotency is also
  exact-line-only (a covering glob or a trailing comment causes a duplicate append).

---

## What's genuinely good (don't overcorrect)

- Real analyzer parse (correct on all Dart 3.x syntax), syntax-only so it needs no `pub get` and
  never breaks on unresolved deps — a smart, robust choice.
- Frozen wire format + deterministic build + `check()` gate — real engineering discipline.
- The provider ambiguity resolver (per-declaration nodes + reachability refusal) is exactly right.
  It's the template the class resolver should copy.
- 172 tests, and a CHANGELOG that records *rejected* ideas so they aren't re-litigated. Rare and
  valuable.
- The refusal-gated nav path resolution (constant substitution / helper inlining / tear-off
  gate) is careful and mostly sound — it's only the final class-name hop that undoes it.

---

## The concept-level question worth sitting with

The premise is "agents shouldn't grep — hand them a resolved graph." Three things sit in tension
with that:

1. It's **syntax-only name resolution** — a heuristic approximation of what grep + read already
   gives you, but presented with more authority.
2. Freshness is **session-start only**, so mid-session edits drift from the graph.
3. Modern agents grep and read quite well, and that path is always correct and always current.

The tool's real wins are the aggregations grep is bad at — "who reads this provider,"
"transitive impact," "what's untested." Those are worth having. But the value is entirely
contingent on the edges being trustworthy, and today the two silent-wrong-edge classes (same-named
classes, codegen providers) land on exactly the cases where a grepping agent would have been
right. Until #1 and #2 are fixed, the tool can make an agent *more confidently wrong* in the
spots it advertises as its strength. Fix those two and the premise holds up.

## Suggested priority

1. Class-name ambiguity → per-declaration nodes + reachability refusal (kills the wrong nav and
   type edges). **(correctness — highest)**
2. Detect `@riverpod` codegen, or add a prominent "manual providers only" caveat. **(scope)**
3. Fix the `callers` method-ambiguity disclosure; scope `callchain` hazards to the method body.
4. `find` 12-member cap; silent `--json` truncation; `diff` staleness guard; sort `packages/*`.
