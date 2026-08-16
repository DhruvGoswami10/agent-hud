// Pacing policy for the command channel, kept pure (no DOM, no chrome APIs)
// so it can be unit-tested — see tests/test_extension.mjs. Loaded before
// youtube.js by the manifest.
//
// Two rules, each paid for in blood:
//   · A page with no player must never poll. Commands are POPPED off the HUD
//     when fetched, so a video-less tab that polls silently eats the playing
//     tab's button press.
//   · Only a tab that is actually in play may hold a parked (long-poll)
//     connection. Chrome allows 6 sockets per origin; idle tabs holding them
//     starve every other HUD request, including music state and agent events.
(function (root) {
  // How long after the music stops a tab still counts as "in play" — matches
  // the reporting freshness window in youtube.js.
  var PARK_WINDOW = 120000;

  // The floor. Any response that arrives instantly (an older HUD build that
  // ignores wait=1, a 404, or the server evicting the oldest parked poll)
  // must not become a zero-delay spin: measured at 774 req/s, ~1 pegged core
  // and thousands of sockets in TIME_WAIT.
  var MIN_DELAY = 200;

  function shouldPoll(s) {
    return !!s.hasVideo;
  }

  function shouldPark(s) {
    if (!s.hasVideo) return false;
    return !!s.playing || s.now - s.lastPlayingAt <= PARK_WINDOW;
  }

  function nextDelay(r, parked) {
    if (!r || !r.ok) return 3000;   // HUD down or erroring: back well off
    return parked ? MIN_DELAY : 2000;
  }

  root.HUDPolicy = {
    shouldPoll: shouldPoll,
    shouldPark: shouldPark,
    nextDelay: nextDelay,
    PARK_WINDOW: PARK_WINDOW,
    MIN_DELAY: MIN_DELAY,
  };
})(typeof globalThis !== "undefined" ? globalThis : self);
