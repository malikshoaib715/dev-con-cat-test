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
  // A server that accepts the socket but never answers the subscription — a
  // proxy that eats frames, an app server in a bad state — must not strand the
  // panel: silence for this long is treated as a rejection and polling takes
  // over, because polling answers definitively.
  var CONFIRM_TIMEOUT_MS = 4000;
  // The verdict is written before the certificate and the settlement (§9), so
  // their info frames arrive moments after final_verdict. The socket stays open
  // this much longer to carry them; the deadline above still bounds everything.
  var FINAL_LINGER_MS = 2000;

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
  // No session_started emit here: this runs while the pixel is still defining
  // itself, so no listener can exist yet. The event is replayed to every
  // listener as it attaches (see onActivity) — that is what makes the panel's
  // session label work however late an async host page binds.
  postJson("/visit", {
    session_id: SESSION.session_id,
    pixel_id: SESSION.pixel_id,
    page_url: SESSION.page_url,
    referrer: SESSION.referrer,
    started_at: SESSION.started_at,
  });

  // --- form instrumentation -------------------------------------------------
  // Field-level churn is emitted for the panel to render locally as it happens;
  // nothing is transmitted per event, so a visitor tabbing through a form never
  // writes a row per keystroke into the audit spine (§6). The accumulated
  // summary leaves the page exactly once, alongside the lead it explains
  // (see submitLead).
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
      if (!field.name) return;
      // A checkbox or radio carries its value attribute whether or not it is
      // selected — `.value` on an unticked consent box is still "on". Only the
      // selected ones exist in a native submission, and a payload that is kept
      // as consent evidence must never claim a box was ticked when it was not.
      if ((field.type === "checkbox" || field.type === "radio") && !field.checked) return;
      values[field.name] = field.value;
    });

    var lead = {
      session_id: SESSION.session_id,
      pixel_id: SESSION.pixel_id,
      form_dwell_ms: Date.now() - new Date(SESSION.started_at).getTime(),
      page_url: SESSION.page_url,
      fields: values,
      // The one moment the interaction summary leaves the page (§6): capped, so
      // a visitor who sat on the form all afternoon still produces one bounded
      // write, and the server persists it on the visit this session began with.
      interactions: SESSION.interactions.slice(0, 100),
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
      // The server settles a repeat submission of the same session against the
      // lead it already has, so nothing is verified twice and nothing is charged
      // twice. Said out loud, because the panel is about to replay that lead's
      // history and an unannounced replay is indistinguishable from a second
      // verification that happened to reach the same verdict.
      if (result.body.replayed) {
        emit({
          type: "info",
          message: "already submitted — showing the original verification for " + result.body.lead_id,
        });
      }

      watchVerification(result.body.lead_id, result.body.stream_token);
    });
  }

  // --- live verification activity -------------------------------------------
  // The ladder is: socket, then reconnects with capped backoff, then polling. Any
  // rung can deliver the whole verification on its own; each is only a fallback
  // for the one above failing.
  //
  // Both transports send frames stamped with their audit event id, and `seen`
  // remembers every id delivered. That is what makes the rungs composable:
  // ingestion writes frames before the page can possibly have subscribed, so
  // every confirmed subscription starts with a catch-up read, and a socket that
  // later falls back to polling re-reads history — without the ids, either path
  // would paint the same rows twice.
  function watchVerification(leadId, streamToken) {
    if (!streamToken) {
      emit({ type: "info", message: "activity stream unavailable for " + leadId });
      return;
    }
    var watch = {
      leadId: leadId,
      token: streamToken,
      cursor: 0,
      seen: {},
      attempts: 0,
      socket: null,
      polling: false,
      pollTimer: null,
      confirmTimer: null,
      lingerTimer: null,
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
    clearTimeout(watch.confirmTimer);
    clearTimeout(watch.lingerTimer);
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
  // server, so both transports hand them over untouched — each one once, however
  // many transports carried it.
  //
  // The verdict does not stop the watch on the spot: the certificate and
  // settlement frames are written just after it, and a socket closed at the
  // verdict would never show them. A short linger carries the housekeeping;
  // polling needs none, because its `done` flag already follows a full page.
  function deliver(watch, frame) {
    if (watch.finished || !frame || !frame.type) return;
    if (frame.id) {
      if (watch.seen[frame.id]) return;
      watch.seen[frame.id] = true;
    }

    emit(frame);
    if (frame.type === "final_verdict" && !watch.lingerTimer) {
      watch.lingerTimer = setTimeout(function () {
        stopWatching(watch);
      }, FINAL_LINGER_MS);
    }
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
    if (watch.finished || watch.polling) return;

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
      clearTimeout(watch.confirmTimer);
      watch.confirmTimer = setTimeout(function () {
        startPolling(watch);
      }, CONFIRM_TIMEOUT_MS);
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
        clearTimeout(watch.confirmTimer);
        // Announced here rather than at submit time, so the word means what it
        // says: the server has accepted the token and frames are now flowing.
        emit({ type: "info", message: "Subscribed to activity for " + watch.leadId });
        // Everything written before this confirmation — the reserved-credits
        // frame always, whole layers when they are quick — was broadcast to a
        // page that was not yet listening. Fetched once here; `seen` keeps the
        // overlap from painting twice.
        catchUp(watch);
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

  // The polling guard matters here: a deliberate close on the way into polling
  // still fires the socket's close event, and without the guard that event
  // would start a second, competing transport.
  function reconnectOrPoll(watch) {
    if (watch.finished || watch.polling) return;

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
  // One-way and idempotent — however many paths lead here (constructor failure,
  // exhausted reconnects, rejection, confirmation silence), one poll loop runs.
  function startPolling(watch) {
    if (watch.finished || watch.polling) return;
    watch.polling = true;

    clearTimeout(watch.confirmTimer);
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

  function activityUrl(watch, since) {
    return (
      CONFIG.endpoint +
      "/leads/" +
      encodeURIComponent(watch.leadId) +
      "/activity?token=" +
      encodeURIComponent(watch.token) +
      "&since=" +
      since
    );
  }

  // The one-off read behind a confirmed subscription. From zero, deliberately:
  // the socket carries no cursor, so only a full read can say what it missed —
  // and `seen` already knows what the page has.
  function catchUp(watch) {
    getJson(activityUrl(watch, 0)).then(function (activity) {
      if (watch.finished || !activity) return;

      (activity.events || []).forEach(function (frame) {
        deliver(watch, frame);
      });
      if (activity.done) stopWatching(watch);
    });
  }

  function poll(watch) {
    if (watch.finished) return;

    getJson(activityUrl(watch, watch.cursor)).then(function (activity) {
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
      // The session began while this file was still defining itself, before any
      // listener could exist — replayed here so a page binding late (which an
      // async snippet guarantees) still gets the event its session label reads.
      try {
        listener({ type: "session_started", session: SESSION });
      } catch (error) {
        // The listener's failures are its own, on replay as on any emit.
      }
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
