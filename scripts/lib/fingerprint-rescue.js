// scripts/lib/fingerprint-rescue.js — Phase 13: weak-fingerprint selector rescue.
//
// Browser-side scoring algorithm. Runs inside the page via `browser-extract
// --eval`. Receives a target fingerprint + threshold (inlined as constants by
// scripts/lib/memory.sh::memory_fingerprint_rescue before eval) and returns
// the synthesised selector for the highest-scoring DOM element above
// threshold, or null on miss.
//
// Fingerprint shape (parsed bash-side from the cached CSS selector — "weak"
// because we don't capture rich state at record-time):
//   { tag:    "BUTTON" | "*",        // upper-case HTML tag, or wildcard
//     classes: ["delete", "btn"],     // class tokens (.foo.bar in selector)
//     attrs:  { id: "...", role: "..." }  // [name=value] selectors + #id
//   }
//
// Scoring (algorithm cribbed from Scrapling adaptive parser, simplified for
// CSS-selector inputs):
//   score = 0.4 × tag_match
//         + 0.4 × jaccard(classes_target, classes_candidate)
//         + 0.2 × jaccard(attrs_target,   attrs_candidate)
//
// Synthesised selector priority (locked design choice):
//   1. #id        when id is alphanumeric/hyphen and resolves uniquely
//   2. [data-testid="…"]      preferred test-automation hook
//   3. tag.class[.class…]     when this combination resolves uniquely
//   4. nth-child path         absolute last-resort fallback
//
// Output (returned to bash via the eval channel):
//   {"rescued_selector": "#submit-btn", "score": 0.82, "candidates_scanned": 1247}
//   {"rescued_selector": null,          "score": 0.0,  "candidates_scanned": 1247}
//
// Phase 13. Best-effort — failure throws nothing; caller treats null as miss.

(() => {
  // __FP and __TH are constants prepended by memory_fingerprint_rescue.
  // eslint-disable-next-line no-undef
  const target = typeof __FP !== "undefined" ? __FP : { tag: "*", classes: [], attrs: {} };
  // eslint-disable-next-line no-undef
  const threshold = typeof __TH !== "undefined" ? __TH : 0.7;

  function jaccard(a, b) {
    if (a.length === 0 && b.length === 0) return 1.0;
    const setA = new Set(a);
    const setB = new Set(b);
    let intersect = 0;
    setA.forEach((x) => { if (setB.has(x)) intersect++; });
    const union = new Set([...setA, ...setB]).size;
    return union === 0 ? 0 : intersect / union;
  }

  function score(el) {
    const tagScore = target.tag === "*" || el.tagName === target.tag ? 1.0 : 0.0;
    const candidateClasses = Array.from(el.classList);
    const classScore = jaccard(target.classes, candidateClasses);
    const targetAttrPairs = Object.entries(target.attrs).map(([k, v]) => `${k}=${v}`);
    const candidateAttrPairs = Array.from(el.attributes).map((a) => `${a.name}=${a.value}`);
    const attrScore = jaccard(targetAttrPairs, candidateAttrPairs);
    return 0.4 * tagScore + 0.4 * classScore + 0.2 * attrScore;
  }

  function isSafeIdent(s) {
    return typeof s === "string" && /^[A-Za-z][\w-]*$/.test(s);
  }

  function synthesise(el) {
    // 1. #id (safe identifier + uniquely resolving)
    if (el.id && isSafeIdent(el.id)) {
      const sel = "#" + el.id;
      try {
        if (document.querySelectorAll(sel).length === 1) return sel;
      } catch (_) { /* invalid selector — fall through */ }
    }
    // 2. [data-testid="…"]
    const testid = el.getAttribute("data-testid");
    if (testid) {
      const sel = '[data-testid="' + testid.replace(/"/g, '\\"') + '"]';
      try {
        if (document.querySelectorAll(sel).length === 1) return sel;
      } catch (_) { /* fall through */ }
    }
    // 3. tag.class[.class…] when uniquely resolving
    if (el.classList.length > 0) {
      const safeClasses = Array.from(el.classList).filter(isSafeIdent);
      if (safeClasses.length > 0) {
        const sel = el.tagName.toLowerCase() + "." + safeClasses.join(".");
        try {
          if (document.querySelectorAll(sel).length === 1) return sel;
        } catch (_) { /* fall through */ }
      }
    }
    // 4. nth-child path — climb to BODY
    const path = [];
    let cur = el;
    while (cur && cur.tagName !== "HTML" && cur.parentElement) {
      const parent = cur.parentElement;
      const idx = Array.prototype.indexOf.call(parent.children, cur) + 1;
      path.unshift(cur.tagName.toLowerCase() + ":nth-child(" + idx + ")");
      if (parent.tagName === "BODY") break;
      cur = parent;
    }
    return path.length > 0 ? path.join(" > ") : null;
  }

  let best = null;
  let bestScore = 0;
  let scanned = 0;
  // Use a NodeList iterator — querySelectorAll('*') returns DOM order. Stable.
  const all = document.querySelectorAll("*");
  for (let i = 0; i < all.length; i++) {
    scanned++;
    const s = score(all[i]);
    if (s > bestScore) {
      bestScore = s;
      best = all[i];
    }
  }
  const rescued = best && bestScore >= threshold ? synthesise(best) : null;
  return {
    rescued_selector: rescued,
    score: Math.round(bestScore * 100) / 100,
    candidates_scanned: scanned,
  };
})();
