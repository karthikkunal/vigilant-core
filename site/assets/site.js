/* vigilant-core marketing site behaviour.
 *
 * Three small things, all progressive enhancements:
 *   1. the theme toggle (explicit choice wins over prefers-color-scheme)
 *   2. a stuck-state border on the sticky header
 *   3. reveal-on-scroll for sections
 *
 * The theme is applied by a tiny inline script in each page's <head> before
 * first paint, so nothing here has to fight a flash of the wrong palette.
 */

(function () {
  "use strict";

  var root = document.documentElement;

  /* ------------------------------------------------------------- theme -- */

  var STORAGE_KEY = "vigilant-core-theme";

  function readStoredTheme() {
    try {
      var stored = window.localStorage.getItem(STORAGE_KEY);
      return stored === "light" || stored === "dark" ? stored : null;
    } catch (error) {
      // Private mode, disabled storage, or a sandboxed iframe. Fall through to
      // the OS preference rather than throwing.
      return null;
    }
  }

  function systemTheme() {
    return window.matchMedia("(prefers-color-scheme: light)").matches
      ? "light"
      : "dark";
  }

  function applyTheme(theme) {
    root.setAttribute("data-theme", theme);
    root.style.colorScheme = theme;

    var toggle = document.querySelector("[data-theme-toggle]");
    if (toggle) {
      var next = theme === "dark" ? "light" : "dark";
      toggle.setAttribute(
        "aria-label",
        "Switch to " + next + " theme (currently " + theme + ")"
      );
    }

    var meta = document.querySelector('meta[name="theme-color"]');
    if (meta) {
      meta.setAttribute("content", theme === "dark" ? "#0b1020" : "#f5f7fb");
    }
  }

  // Adopt whatever the head script decided, so the toggle's label matches.
  applyTheme(root.getAttribute("data-theme") || systemTheme());

  var toggle = document.querySelector("[data-theme-toggle]");
  if (toggle) {
    toggle.addEventListener("click", function () {
      var next = (root.getAttribute("data-theme") === "dark" ? "light" : "dark");
      applyTheme(next);
      try {
        window.localStorage.setItem(STORAGE_KEY, next);
      } catch (error) {
        // A theme that cannot be remembered is still a working theme.
      }
    });
  }

  // Follow the OS only while the reader has not expressed a preference.
  var media = window.matchMedia("(prefers-color-scheme: light)");
  var onChange = function (event) {
    if (!readStoredTheme()) {
      applyTheme(event.matches ? "light" : "dark");
    }
  };
  if (typeof media.addEventListener === "function") {
    media.addEventListener("change", onChange);
  } else if (typeof media.addListener === "function") {
    media.addListener(onChange);
  }

  /* ------------------------------------------------------------- header -- */

  var header = document.querySelector("[data-header]");
  if (header) {
    var onScroll = function () {
      header.setAttribute("data-stuck", window.scrollY > 8 ? "true" : "false");
    };
    onScroll();
    window.addEventListener("scroll", onScroll, { passive: true });
  }

  /* ------------------------------------------------------------- reveal -- */

  var targets = document.querySelectorAll("[data-reveal]");

  if (
    targets.length &&
    "IntersectionObserver" in window &&
    !window.matchMedia("(prefers-reduced-motion: reduce)").matches
  ) {
    var observer = new IntersectionObserver(
      function (entries) {
        entries.forEach(function (entry) {
          if (!entry.isIntersecting) return;
          entry.target.classList.add("is-visible");
          observer.unobserve(entry.target);
        });
      },
      { rootMargin: "0px 0px -8% 0px", threshold: 0.08 }
    );

    Array.prototype.forEach.call(targets, function (node) {
      observer.observe(node);
    });
  } else {
    Array.prototype.forEach.call(targets, function (node) {
      node.classList.add("is-visible");
    });
  }
})();
