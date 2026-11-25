const ACCEPTED_ORIGINS = new Set([
  "https://huos-v2-prive-pilot.vercel.app",
  "https://mijn.horecaunited.nl",
]);

const TURNSTILE_HOSTS = new Set([
  "huos-v2-prive-pilot.vercel.app",
  "mijn.horecaunited.nl",
]);

export function isAcceptedOrigin(origin) {
  return ACCEPTED_ORIGINS.has(origin);
}

export function isValidTurnstileChallenge(check) {
  return check.success === true &&
    TURNSTILE_HOSTS.has(check.hostname ?? "") &&
    check.action === "beer_intake";
}
