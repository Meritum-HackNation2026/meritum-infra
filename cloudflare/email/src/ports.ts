/**
 * The Worker's environment: the `send_email` binding, secrets and variables of wrangler.toml.
 *
 * @feature US-POW-05, US-MOD-01, F-26
 */

/**
 * One message in the structured form of the `send_email` binding (Cloudflare Email Service).
 *
 * @feature US-POW-05, US-MOD-01, F-26
 */
export type EmailMessageBuilder = {
  from: string
  to: string
  subject: string
  text: string
}

/**
 * The `send_email` binding; tests pass a fake with the same shape.
 *
 * @feature US-POW-05, US-MOD-01, F-26
 */
type SendEmail = {
  send(message: EmailMessageBuilder): Promise<{ messageId: string }>
}

/**
 * Bindings, secrets and variables the Worker reads.
 *
 * @feature US-POW-05, US-MOD-01, F-26
 */
export type Env = {
  /** `send_email` binding; Cloudflare delivers only to verified destination addresses. */
  SEND_EMAIL: SendEmail
  /** Secret shared with the backend; signs each request with HMAC-SHA256. */
  SIGNING_SECRET: string
  /** Secret: comma-separated moderator addresses verified in Email Routing. */
  MODERATOR_ADDRESSES: string
  /** Sender on the domain with Email Routing (wrangler.toml). */
  FROM_ADDRESS: string
  /** Comma-separated origins a panel link may start with (wrangler.toml). */
  PANEL_ORIGINS: string
}
