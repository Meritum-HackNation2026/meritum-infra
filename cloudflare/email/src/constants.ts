/**
 * Constants of the moderator e-mail Worker.
 *
 * @feature US-POW-05, US-MOD-01, F-26
 */

/**
 * Header with the request time in Unix seconds, part of the signed text.
 *
 * @feature US-POW-05, US-MOD-01, F-26
 */
export const TIMESTAMP_HEADER = 'x-meritum-timestamp'

/**
 * Header with `sha256=<hex HMAC-SHA256 of "<timestamp>.<body>">`.
 *
 * @feature US-POW-05, US-MOD-01, F-26
 */
export const SIGNATURE_HEADER = 'x-meritum-signature'

/**
 * Prefix of the signature header value.
 *
 * @feature US-POW-05, US-MOD-01, F-26
 */
export const SIGNATURE_PREFIX = 'sha256='

/**
 * Oldest (and furthest in the future) accepted timestamp, in seconds; limits replays.
 *
 * @feature US-POW-05, US-MOD-01, F-26
 */
export const MAX_CLOCK_SKEW_SECONDS = 300

/**
 * Largest accepted request body, in characters; a valid body is far smaller.
 *
 * @feature US-POW-05, US-MOD-01, F-26
 */
export const MAX_BODY_LENGTH = 4096

/**
 * Accepted case number: letters, digits and dashes, so it cannot break the subject line.
 *
 * @feature US-POW-05, US-MOD-01, F-26
 */
export const CASE_PATTERN = /^[A-Za-z0-9-]{1,64}$/

/**
 * Separator of the list variables (MODERATOR_ADDRESSES, PANEL_ORIGINS).
 *
 * @feature US-POW-05, US-MOD-01, F-26
 */
export const LIST_SEPARATOR = ','

/**
 * Placeholder of the case number in the copy text.
 *
 * @feature US-POW-05, US-MOD-01, F-26
 */
export const CASE_PLACEHOLDER = '{case}'
