import assert from "node:assert/strict";
import test from "node:test";

import {
  isAcceptedOrigin,
  isValidTurnstileChallenge,
} from "./origin-policy.mjs";

test("accepts the pilot and production origins", () => {
  assert.equal(
    isAcceptedOrigin("https://huos-v2-prive-pilot.vercel.app"),
    true,
  );
  assert.equal(isAcceptedOrigin("https://mijn.horecaunited.nl"), true);
});

test("rejects origins that are not exact HTTPS allowlist entries", () => {
  for (
    const origin of [
      "",
      "null",
      "http://mijn.horecaunited.nl",
      "https://mijn.horecaunited.nl/",
      "https://sub.mijn.horecaunited.nl",
      "https://mijn.horecaunited.nl.attacker.example",
      "https://localhost:3000",
      "https://malicious-clone.com",
    ]
  ) {
    assert.equal(
      isAcceptedOrigin(origin),
      false,
      `unexpectedly accepted ${origin}`,
    );
  }
});

test("accepts a successful Turnstile challenge for either allowed hostname and action", () => {
  for (
    const hostname of [
      "huos-v2-prive-pilot.vercel.app",
      "mijn.horecaunited.nl",
    ]
  ) {
    assert.equal(
      isValidTurnstileChallenge({
        success: true,
        hostname,
        action: "beer_intake",
      }),
      true,
    );
  }
});

test("rejects unsuccessful, missing-hostname, unexpected-hostname, or wrong-action challenges", () => {
  for (
    const challenge of [
      {
        success: false,
        hostname: "mijn.horecaunited.nl",
        action: "beer_intake",
      },
      { success: true, action: "beer_intake" },
      { success: true, hostname: null, action: "beer_intake" },
      {
        success: true,
        hostname: "sub.mijn.horecaunited.nl",
        action: "beer_intake",
      },
      {
        success: true,
        hostname: "mijn.horecaunited.nl",
        action: "other_action",
      },
    ]
  ) {
    assert.equal(isValidTurnstileChallenge(challenge), false);
  }
});
