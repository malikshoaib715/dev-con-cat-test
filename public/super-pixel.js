/*
 * Super Pixel — production embed snippet
 * --------------------------------------
 * The buyer pastes one tag into their <head>:
 *
 *   <script async src="https://app.example/super-pixel.js"
 *           data-pixel-id="px_9f2a01"
 *           data-pixel-key="pk_…"
 *           data-endpoint="https://app.example/api/pixel"></script>
 *
 * It boots a capture session, beacons the visit, watches the lead form, hands
 * the submission to the ingestion API, and then streams that lead's verification
 * back to the page as each detection layer finishes.
 *
 * The reference example's public surface is kept exactly — window.SuperPixel with
 * config, session, onActivity and attach, auto-attaching to form[data-pixel-form]
 * — so a page written against the example works against this file unmodified. The
 * simulation is gone: every frame this emits now comes from a real verification.
 *
 * Two rules govern everything below.
 *
 * 1. Never break the host page. This runs on somebody else's funnel, where a
 *    thrown exception costs them a sale. Every entry point is wrapped, page
 *    listeners are isolated from each other, network failures resolve to null
 *    rather than rejecting, and the form always submits — only a form marked
 *    data-pixel-demo has its navigation prevented.
 * 2. Never outlive its usefulness. The socket, the reconnect backoff, and the
 *    polling timer all stop at the final verdict or at a hard deadline. No
 *    immortal timers on a buyer's page.
 */
(function () {
  "use strict";

  var RECONNECT_LIMIT = 5;
  var RECONNECT_BASE_MS = 1000;
  var POLL_INTERVAL_MS = 3000;
  var SESSION_DEADLINE_MS = 5 * 60 * 1000;

  var script =
    document.currentScript ||
    (function () {
      var tags = document.getElementsByTagName("script");
      return tags[tags.length - 1];
    })();

  function attribute(name) {
    return (script && script.getAttribute(name)) || null;
  }

  var CONFIG = {
    pixelId: attribute("data-pixel-id"),
    pixelKey: attribute("data-pixel-key"),
    // Without an endpoint there is nothing to talk to. The pixel then does
    // nothing at all rather than guessing at a host.
    endpoint: (attribute("data-endpoint") || "").replace(/\/$/, "") || null,
  };

  // --- event bus ------------------------------------------------------------
  var listeners = [];

  function emit(activity) {
    for (var index = 0; index < listeners.length; index++) {
      try {
        listeners[index](activity);
      } catch (error) {
        // One page listener throwing must not stop the others, or the pixel.
      }
    }
  }

  function generateSessionId() {
    if (window.crypto && typeof window.crypto.randomUUID === "function") {
      return "sess_" + window.crypto.randomUUID();
    }
    return (
      "sess_" +
      Date.now().toString(36) +
      "_" +
      Math.random().toString(36).slice(2, 10)
    );
  }

  var SESSION = {
    session_id: generateSessionId(),
    pixel_id: CONFIG.pixelId,
    page_url: location.href,
    referrer: document.referrer || null,
    user_agent: navigator.userAgent,
    started_at: new Date().toISOString(),
    interactions: [],
  };

  // --- transport ------------------------------------------------------------
  // Resolves to null on any failure, including a non-2xx response. Callers decide
  // what silence means; none of them may throw because of it.
  function postJson(path, body) {
    if (!CONFIG.endpoint) return Promise.resolve(null);

    var headers = { "Content-Type": "application/json" };
    if (CONFIG.pixelKey) headers["X-Pixel-Key"] = CONFIG.pixelKey;

    return fetch(CONFIG.endpoint + path, {
      method: "POST",
      headers: headers,
      body: JSON.stringify(body),
      // Survives the page unloading, which is exactly when the submit beacon
      // would otherwise be cancelled.
      keepalive: true,
    })
      .then(function (response) {
        return response
          .json()
          .then(function (parsed) {
            return { status: response.status, body: parsed };
          })
          .catch(function () {
            return { status: response.status, body: null };
          });
      })
      .catch(function () {
        return null;
      });
  }

  function getJson(url) {
    return fetch(url, { method: "GET" })
      .then(function (response) {
        return response.ok ? response.json() : null;
      })
      .catch(function () {
        return null;
      });
  }

  // --- visit beacon ---------------------------------------------------------
  postJson("/visit", {
    session_id: SESSION.session_id,
    pixel_id: SESSION.pixel_id,
    page_url: SESSION.page_url,
    referrer: SESSION.referrer,
    started_at: SESSION.started_at,
  });
  emit({ type: "session_started", session: SESSION });

  // --- form instrumentation -------------------------------------------------
  // Field-level churn is emitted for the panel to render locally and never sent:
  // a visitor tabbing through a form would otherwise write a row per keystroke
  // into the audit spine (§6). The ingestion endpoint accepts the identity fields
  // and nothing else, so this stays on the page where it belongs.
  function trackForm(form) {
    var fields = form.querySelectorAll("input, select, textarea");

    Array.prototype.forEach.call(fields, function (field) {
      ["focus", "blur", "change"].forEach(function (eventName) {
        field.addEventListener(eventName, function () {
          var interaction = {
            name: field.name || field.id || "(unnamed)",
            action: eventName,
            at: new Date().toISOString(),
          };
          SESSION.interactions.push(interaction);
          emit({ type: "field", interaction: interaction });
        });
      });
    });

    form.addEventListener("submit", function (event) {
      // A real integration lets the form navigate and captures alongside it; the
      // demo page asks us to stay put so the panel remains on screen.
      if (form.hasAttribute("data-pixel-demo")) event.preventDefault();

      try {
        submitLead(fields);
      } catch (error) {
        // The buyer's form has already done its job; ours is never worth an
        // exception on their page.
      }
    });
  }

  function submitLead(fields) {
    var values = {};
    Array.prototype.forEach.call(fields, function (field) {
      if (field.name) values[field.name] = field.value;
    });

    var lead = {
      session_id: SESSION.session_id,
      pixel_id: SESSION.pixel_id,
      form_dwell_ms: Date.now() - new Date(SESSION.started_at).getTime(),
      page_url: SESSION.page_url,
      fields: values,
    };
    emit({ type: "submitted", lead: lead });

    postJson("/leads", lead).then(function (result) {
      if (!result) {
        emit({ type: "info", message: "verification unavailable — lead not submitted" });
        return;
      }
      if (result.status === 402) {
        // Expected, not exceptional: the lead is kept and can be re-run once the
        // buyer tops up. The page is told, and nothing else happens.
        emit({ type: "info", message: "verification on hold — account out of credits" });
        return;
      }
      if (!result.body || !result.body.lead_id) {
        emit({ type: "info", message: "verification unavailable — lead not submitted" });
        return;
      }

      watchVerification(result.body.lead_id, result.body.stream_token);
    });
  }

  // --- live verification activity -------------------------------------------
  // The ladder is: socket, then reconnects with capped backoff, then polling. Any
  // rung can deliver the whole verification on its own; each is only a fallback
  // for the one above failing.
  function watchVerification(leadId, streamToken) {
    if (!streamToken) {
      emit({ type: "info", message: "activity stream unavailable for " + leadId });
      return;
    }
    var watch = {
      leadId: leadId,
      token: streamToken,
      cursor: 0,
      attempts: 0,
      socket: null,
      pollTimer: null,
      deadlineTimer: null,
      finished: false,
    };

    watch.deadlineTimer = setTimeout(function () {
      stopWatching(watch);
    }, SESSION_DEADLINE_MS);

    openSocket(watch);
  }

  function stopWatching(watch) {
    if (watch.finished) return;
    watch.finished = true;

    clearTimeout(watch.deadlineTimer);
    clearTimeout(watch.pollTimer);
    if (watch.socket) {
      try {
        watch.socket.close();
      } catch (error) {
        // Already closing; nothing left to do.
      }
      watch.socket = null;
    }
  }

  // Frames arrive already in the shape the page renders, from PanelFrame on the
  // server, so both transports hand them over untouched.
  function deliver(watch, frame) {
    if (watch.finished || !frame || !frame.type) return;

    emit(frame);
    if (frame.type === "final_verdict") stopWatching(watch);
  }

  function socketUrl() {
    var endpoint = new URL(CONFIG.endpoint, location.href);
    return (
      (endpoint.protocol === "https:" ? "wss:" : "ws:") + "//" + endpoint.host + "/cable"
    );
  }

  // A minimal Action Cable wire client: subscribe, ignore the housekeeping
  // frames, hand the rest to the page. Dependency-free on purpose — asking a
  // buyer to load a bundler or a CDN for one socket is not a snippet.
  function openSocket(watch) {
    if (watch.finished) return;

    var identifier = JSON.stringify({
      channel: "VerificationChannel",
      stream_token: watch.token,
    });
    var socket;

    try {
      socket = new WebSocket(socketUrl());
    } catch (error) {
      startPolling(watch);
      return;
    }
    watch.socket = socket;

    socket.addEventListener("open", function () {
      watch.attempts = 0;
      socket.send(JSON.stringify({ command: "subscribe", identifier: identifier }));
    });

    socket.addEventListener("message", function (event) {
      var parsed;
      try {
        parsed = JSON.parse(event.data);
      } catch (error) {
        return;
      }

      if (parsed.type === "ping" || parsed.type === "welcome") return;
      if (parsed.type === "confirm_subscription") {
        // Announced here rather than at submit time, so the word means what it
        // says: the server has accepted the token and frames are now flowing.
        emit({ type: "info", message: "Subscribed to activity for " + watch.leadId });
        return;
      }
      if (parsed.type === "reject_subscription") {
        // The token was refused outright; reconnecting with it would be refused
        // just as fast. Polling carries the same token and answers definitively.
        startPolling(watch);
        return;
      }
      if (parsed.message) deliver(watch, parsed.message);
    });

    socket.addEventListener("close", function () {
      reconnectOrPoll(watch);
    });
  }

  function reconnectOrPoll(watch) {
    if (watch.finished) return;

    if (watch.attempts >= RECONNECT_LIMIT) {
      startPolling(watch);
      return;
    }

    var delay = RECONNECT_BASE_MS * Math.pow(2, watch.attempts);
    watch.attempts += 1;
    watch.pollTimer = setTimeout(function () {
      openSocket(watch);
    }, delay);
  }

  // Last rung: the same frames, fetched on a timer, authorised by the same token.
  function startPolling(watch) {
    if (watch.finished) return;

    if (watch.socket) {
      try {
        watch.socket.close();
      } catch (error) {
        // Already gone.
      }
      watch.socket = null;
    }

    emit({ type: "info", message: "live stream unavailable — polling for activity" });
    poll(watch);
  }

  function poll(watch) {
    if (watch.finished) return;

    var url =
      CONFIG.endpoint +
      "/leads/" +
      encodeURIComponent(watch.leadId) +
      "/activity?token=" +
      encodeURIComponent(watch.token) +
      "&since=" +
      watch.cursor;

    getJson(url).then(function (activity) {
      if (watch.finished) return;

      if (activity) {
        watch.cursor = activity.cursor || watch.cursor;
        (activity.events || []).forEach(function (frame) {
          deliver(watch, frame);
        });
        if (activity.done) {
          stopWatching(watch);
          return;
        }
      }

      watch.pollTimer = setTimeout(function () {
        poll(watch);
      }, POLL_INTERVAL_MS);
    });
  }

  // --- public API -----------------------------------------------------------
  window.SuperPixel = {
    config: CONFIG,
    session: SESSION,
    onActivity: function (listener) {
      listeners.push(listener);
    },
    attach: trackForm,
  };

  // A production snippet is `async`, so a host page's own script may well run
  // before this file does and find window.SuperPixel missing. This is how such a
  // page knows when to bind its listener; a page loading the tag synchronously
  // can keep checking for the global and never see this at all.
  try {
    document.dispatchEvent(
      new CustomEvent("superpixel:ready", { detail: window.SuperPixel })
    );
  } catch (error) {
    // An environment without CustomEvent still has the global; only the
    // convenience is lost.
  }

  function boot() {
    try {
      var forms = document.querySelectorAll("form[data-pixel-form]");
      Array.prototype.forEach.call(forms, trackForm);
    } catch (error) {
      // A page we cannot instrument is a page we leave alone.
    }
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", boot);
  } else {
    boot();
  }
})();
